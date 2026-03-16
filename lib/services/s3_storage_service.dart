import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 's3_signer.dart';

// ====================[新增] 文件并发写入互斥锁 ====================
class FileMutex {
  Future<void>? _last;
  Future<void> synchronized(Future<void> Function() action) async {
    final previous = _last;
    final completer = Completer<void>();
    _last = completer.future;
    if (previous != null) { await previous.catchError((_) {}); }
    try { await action(); } finally { completer.complete(); }
  }
}

// ==================== [增强] 高级传输状态机 ====================
class PartInfo {
  final int partNumber;
  double progress;
  String speed;
  PartInfo(this.partNumber, this.progress, this.speed);
}

class TransferTask extends ChangeNotifier {
  final String id = UniqueKey().toString();
  final String fileName;
  final bool isUpload;
  
  bool isCancelled = false;
  bool isFinished = false;
  bool isError = false;
  String errorMessage = '';

  double overallProgress = 0.0;
  String overallSpeed = '等待中...';
  
  Map<int, PartInfo> parts = {};

  // [核心修复1]: 限制前端渲染数量，防止卡顿。只显示正在跑的，和最新的 6 个已完成分片。
  List<PartInfo> get visibleParts {
    final active = parts.values.where((p) => p.progress < 1.0).toList();
    final completed = parts.values.where((p) => p.progress >= 1.0).toList().reversed.take(6).toList();
    final combined = [...active, ...completed];
    combined.sort((a,b) => a.partNumber.compareTo(b.partNumber));
    return combined;
  }

  TransferTask(this.fileName, {this.isUpload = true});

  void updateOverall(double p, String s) {
    overallProgress = p; overallSpeed = s; notifyListeners();
  }

  void updatePart(int partNum, double p, String s) {
    if (!parts.containsKey(partNum)) {
      parts[partNum] = PartInfo(partNum, p, s);
    } else {
      parts[partNum]!.progress = p; parts[partNum]!.speed = s;
    }
    notifyListeners(); 
  }

  void cancel() {
    isCancelled = true; errorMessage = '用户取消'; notifyListeners();
  }

  // 接收一个移除回调，实现完成后的自动销毁
  void complete(Function(TransferTask)? onRemove) {
    isFinished = true; overallProgress = 1.0; overallSpeed = '已完成'; notifyListeners();
    // [核心修复2]: 3秒后自动清除完成的任务
    if (onRemove != null) {
      Future.delayed(const Duration(seconds: 3), () => onRemove(this));
    }
  }

  void error(String msg) {
    isError = true; errorMessage = msg; overallSpeed = '失败'; notifyListeners();
  }
}

class TransferManager extends ChangeNotifier {
  List<TransferTask> tasks =[];
  
  void addTask(TransferTask task) {
    tasks.insert(0, task); notifyListeners();
  }
  
  void removeTask(TransferTask task) {
    tasks.remove(task); notifyListeners();
  }
  
  int get activeCount => tasks.where((t) => !t.isFinished && !t.isError && !t.isCancelled).length;
}

String formatSize(double bytes) {
  if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(2)} KB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}

class S3StorageService with ChangeNotifier {
  String? _ak;
  String? _sk;
  String? _endpoint;
  String? _bucket;
  String? currentBucket;
  bool isInit = false; 
  
  bool get isConfigured => _ak != null && _sk != null && _endpoint != null && _bucket != null && currentBucket != null;

  // ==================== [新增] 外链管理中心状态 ====================
  List<Map<String, dynamic>> _shareHistory =[];
  List<Map<String, dynamic>> get shareHistory => _shareHistory;

  Future<void> loadShareHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyStr = prefs.getString('share_history') ?? '[]';
    List<dynamic> list = jsonDecode(historyStr);
    _shareHistory = list.cast<Map<String, dynamic>>();
    
    // 自动清理已经过期的链接
    final now = DateTime.now().millisecondsSinceEpoch;
    _shareHistory.removeWhere((item) => item['expireAt'] < now);
    await prefs.setString('share_history', jsonEncode(_shareHistory));
    notifyListeners();
  }

  Future<String> generateAndSaveShareUrl(String key, String fileName) async {
    final url = await getShareUrl(key, fileName);
    final prefs = await SharedPreferences.getInstance();
    final expiresIn = prefs.getInt('link_expire_seconds') ?? 86400;
    final expireAt = DateTime.now().millisecondsSinceEpoch + (expiresIn * 1000);

    _shareHistory.insert(0, {
      'fileName': fileName,
      'key': key,
      'url': url,
      'expireAt': expireAt,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    await prefs.setString('share_history', jsonEncode(_shareHistory));
    notifyListeners();
    return url;
  }

  Future<void> deleteShareRecord(int index) async {
    _shareHistory.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('share_history', jsonEncode(_shareHistory));
    notifyListeners();
  }

  // ==================== [修正] 获取外链（带时间配置） ====================
  Future<String> getShareUrl(String key, String fileName) async {
    if (!isConfigured) return '';
    final prefs = await SharedPreferences.getInstance();
    final expiresIn = prefs.getInt('link_expire_seconds') ?? 86400; 

    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(key);
    // 只生成链接并返回，不再在此处向 SharedPreferences 写数据，避免与 generateAndSaveShareUrl 冲突
    return S3Signer.generatePresignedUrl(
      endpoint: _endpoint!, host: host, path: path, ak: _ak!, sk: _sk!, expiresIn: expiresIn
    );
  }

  // ==================== [新增] 获取云端已上传的碎片 (用于断点续传) ====================
  Future<List<Map<String, dynamic>>> _listParts(String key, String uploadId) async {
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(key);
    final headers = S3Signer.generateV4Headers(method: 'GET', host: host, path: path, queryParams: {'uploadId': uploadId}, ak: _ak!, sk: _sk!);
    final res = await http.get(Uri.parse('$_endpoint$path?uploadId=$uploadId'), headers: headers);
    if (res.statusCode != 200) throw Exception("获取分片列表失败");

    List<Map<String, dynamic>> parts =[];
    final matches = RegExp(r'<Part>.*?<PartNumber>(\d+)</PartNumber>.*?<ETag>(.*?)</ETag>.*?</Part>', dotAll: true).allMatches(res.body);
    for (final m in matches) {
      parts.add({'PartNumber': int.parse(m.group(1)!), 'ETag': m.group(2)!});
    }
    return parts;
  }

  static const int _partSize = 5 * 1024 * 1024; // 5MB 分片界限

  S3StorageService() { _loadConfig(); }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final ak = prefs.getString('ak')?.trim() ?? '';
    final sk = prefs.getString('sk')?.trim() ?? '';
    final endpoint = prefs.getString('endpoint')?.trim() ?? '';
    final bucket = prefs.getString('bucket')?.trim() ?? '';

    if (ak.isNotEmpty && sk.isNotEmpty && endpoint.isNotEmpty && bucket.isNotEmpty) {
      try {
        await connect(ak, sk, endpoint, bucket, save: false);
      } catch (e) {
        debugPrint("自动登录失败: $e");
      }
    }
    isInit = true;
    notifyListeners();
  }

  String _sanitizeKey(String key) {
    String clean = key.trim();
    while (clean.startsWith('/')) {
      clean = clean.substring(1);
    }
    return clean;
  }

  /// 构建标准的 S3 Path
  String _encodePath(String key) {
    if (key.isEmpty) return '/${_bucket!}/';
    // 使用S3Signer.uriEncode来正确编码路径中的特殊字符，包括中文
    final encodedKey = key.split('/').map((s) => S3Signer.uriEncode(s)).join('/');
    return '/${_bucket!}/$encodedKey';
  }

  Future<void> connect(String ak, String sk, String endpoint, String bucket, {bool save = true}) async {
    try {
      String cleanEndpoint = endpoint.trim();
      while (cleanEndpoint.endsWith('/')) {
        cleanEndpoint = cleanEndpoint.substring(0, cleanEndpoint.length - 1);
      }
      String cleanBucket = bucket.trim().replaceAll('/', '');

      _ak = ak.trim();
      _sk = sk.trim();
      _endpoint = cleanEndpoint;
      _bucket = cleanBucket;
      currentBucket = cleanBucket;

      await listFiles('');

      if (save) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ak', ak.trim());
        await prefs.setString('sk', sk.trim());
        await prefs.setString('endpoint', cleanEndpoint);
        await prefs.setString('bucket', cleanBucket);
      }
      isInit = true;
      notifyListeners();
    } catch (e) {
      _ak = null; _sk = null; _endpoint = null; _bucket = null; currentBucket = null;
      throw Exception("认证失败: $e");
    }
  }


  // ==================== [修正] 递归删除并抹除 0 字节标记 ====================
  Future<void> deleteItem(String key, bool isDir) async {
    if (!isConfigured) return;
    final cleanKey = _sanitizeKey(key);

    if (isDir) {
      // 保证文件夹删除操作一定带有后缀 '/'
      final dirPrefix = cleanKey.endsWith('/') ? cleanKey : '$cleanKey/';
      final items = await listFiles(dirPrefix);
      
      // 1. 递归先删除文件夹内部的所有文件/子目录
      for (final item in items) {
        await deleteItem(item['key']!, item['isDir']);
      }
      
      // 2. 内部清空后，必须发起一次 DELETE 请求，抹除这个 0 字节的原生标记对象
      await _deleteSingleItem(dirPrefix, true);
    } else {
      await _deleteSingleItem(cleanKey, false);
    }
  }

  Future<void> _deleteSingleItem(String key, bool isDir) async {
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(key);
    
    final headers = S3Signer.generateV4Headers(
      method: 'DELETE',
      host: host,
      path: path,
      ak: _ak!,
      sk: _sk!,
    );

    final response = await http.delete(Uri.parse('$_endpoint$path'), headers: headers);
    
    // HTTP 204 No Content 是 S3 DELETE 成功的标准返回码
    if (response.statusCode != 204 && response.statusCode != 200) {
      final errBody = utf8.decode(response.bodyBytes);
      throw Exception("删除失败: ${response.statusCode} - $errBody");
    }
  }


  // ==================== [修正] 官方标准 S3 原生文件夹创建 ====================
  Future<void> createFolder(String currentPrefix, String folderName) async {
    if (!isConfigured) return;
    final cleanPrefix = _sanitizeKey(currentPrefix);
    String newKey = cleanPrefix + folderName;
    if (!newKey.endsWith('/')) newKey += '/'; // 官方要求：必须以 / 结尾
    
    // 官方方案：直接调用 putObject，上传一个 0 字节的空内容
    await _uploadSingleFile(newKey, Uint8List(0));
  }

  // ==================== [终极修复] 100% 容错解析原生目录标记 ====================
  Future<List<Map<String, dynamic>>> listFiles(String prefix) async {
    if (!isConfigured) throw Exception("请先配置账户");
    final cleanPrefix = _sanitizeKey(prefix);
    final endpointUri = Uri.parse(_endpoint!);
    
    final queryParams = {'delimiter': '/', 'list-type': '2', 'prefix': cleanPrefix};
    final path = '/${_bucket!}/';
    
    final headers = S3Signer.generateV4Headers(
      method: 'GET',
      host: endpointUri.host,
      path: path,
      queryParams: queryParams,
      ak: _ak!,
      sk: _sk!,
    );

    final sortedKeys = queryParams.keys.toList()..sort();
    final queryParts = sortedKeys.map((k) => '${S3Signer.uriEncode(k)}=${S3Signer.uriEncode(queryParams[k]!)}');
    final url = '$_endpoint$path?${queryParts.join('&')}';
    
    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) throw Exception("列出文件失败: ${response.statusCode}");

    final responseBody = utf8.decode(response.bodyBytes);
    List<Map<String, dynamic>> items =[];

    // 1. 提取 CommonPrefixes 块 (无视换行符，dotAll: true 代表 . 可以匹配换行)
    final commonPrefixesMatches = RegExp(r'<CommonPrefixes>(.*?)</CommonPrefixes>', dotAll: true).allMatches(responseBody);
    for (final m in commonPrefixesMatches) {
      final prefixBlock = m.group(1)!;
      // 在块内单独提取 Prefix
      final prefixMatch = RegExp(r'<Prefix>(.*?)</Prefix>').firstMatch(prefixBlock);
      if (prefixMatch != null) {
        final prefixStr = prefixMatch.group(1)!;
        
        String name = prefixStr;
        // 安全地移除前缀路径
        if (cleanPrefix.isNotEmpty && name.startsWith(cleanPrefix)) {
          name = name.substring(cleanPrefix.length);
        }
        name = name.replaceAll('/', ''); // 仅保留单纯的文件夹名
        
        if (name.isNotEmpty && !items.any((e) => e['name'] == name && e['isDir'])) {
          items.add({'name': name, 'isDir': true, 'size': 0, 'key': prefixStr});
        }
      }
    }

    // 2. 提取 Contents 块 (文件或当前层级的 0 字节原生目录标记)
    final contentsMatches = RegExp(r'<Contents>(.*?)</Contents>', dotAll: true).allMatches(responseBody);
    for (final m in contentsMatches) {
      final contentBlock = m.group(1)!;
      // 在块内单独提取各项属性，彻底无视节点排列顺序
      final keyMatch = RegExp(r'<Key>(.*?)</Key>').firstMatch(contentBlock);
      final sizeMatch = RegExp(r'<Size>(\d+)</Size>').firstMatch(contentBlock);
      final timeMatch = RegExp(r'<LastModified>(.*?)</LastModified>').firstMatch(contentBlock);
      
      if (keyMatch != null && sizeMatch != null) {
        final key = keyMatch.group(1)!;
        final size = int.parse(sizeMatch.group(1)!);
        final time = timeMatch?.group(1) ?? '';
        
        String name = key;
        if (cleanPrefix.isNotEmpty && name.startsWith(cleanPrefix)) {
          name = name.substring(cleanPrefix.length);
        }
        
        // 过滤掉当前目录自身的 0 字节标记 (避免自己显示在自己里面)
        if (key != cleanPrefix && name.isNotEmpty) {
          // 判断是否为 S3 原生目录对象 (以 / 结尾)
          if (key.endsWith('/')) {
            final dirName = name.replaceAll('/', '');
            if (!items.any((e) => e['name'] == dirName && e['isDir'])) {
              items.add({'name': dirName, 'isDir': true, 'size': 0, 'key': key, 'time': time});
            }
          } else {
            items.add({'name': name, 'isDir': false, 'size': size, 'key': key, 'time': time});
          }
        }
      }
    }
    
    // 顺手屏蔽掉旧版本可能残留的 VFS 配置文件
    items.removeWhere((e) => e['name'] == '.osca_vfs.json');
    return items;
  }

  // ==================== [终极进化] 极速并发下载引擎 ====================
  Future<void> downloadFile(String key, String localPath, int fileSize, TransferTask task) async {
    if (!isConfigured) return;
    
    final file = File(localPath);
    // [核心技术]：预先撑开占位文件，以便多个线程在不同的 Offset 随意写入
    final raf = await file.open(mode: FileMode.write);
    await raf.truncate(fileSize); 

    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(_sanitizeKey(key));
    
    final mutex = FileMutex(); // 保证硬盘写入指针不出错
    int activeDownloads = 0;
    List<Future<void>> allTasks =[];
    bool hasError = false;
    String errorMsg = "";
    int downloadedBytes = 0;
    final startT = DateTime.now().millisecondsSinceEpoch;

    // 分片下载核心函数
    Future<void> downloadPart(int start, int end, int pNum) async {
      final headers = S3Signer.generateV4Headers(method: 'GET', host: host, path: path, extraHeaders: {'Range': 'bytes=$start-$end', 'Connection': 'close'}, ak: _ak!, sk: _sk!);
      final req = http.Request('GET', Uri.parse('$_endpoint$path'))..headers.addAll(headers);
      final client = http.Client();
      try {
        final res = await client.send(req);
        if (res.statusCode != 206 && res.statusCode != 200) throw Exception("HTTP ${res.statusCode}");
        
        // 1. 将 5MB 分片下载到内存中
        final builder = BytesBuilder();
        await for (final chunk in res.stream) {
          if (task.isCancelled) throw Exception("取消");
          builder.add(chunk);
          downloadedBytes += chunk.length;
          
          final el = (DateTime.now().millisecondsSinceEpoch - startT) / 1000.0;
          task.updateOverall(downloadedBytes / fileSize.toDouble(), el > 0 ? '${formatSize(downloadedBytes / el)}/s' : '...');
          task.updatePart(pNum, builder.length / (end - start + 1), '下载中');
        }
        
        // 2. 利用互斥锁安全写入硬盘对应位置
        final fullBytes = builder.takeBytes();
        await mutex.synchronized(() async {
          await raf.setPosition(start);
          await raf.writeFrom(fullBytes);
        });
        task.updatePart(pNum, 1.0, '完成');
      } finally {
        client.close();
      }
    }

    // 滑动窗口并发切割下载
    for (int i = 0; i < fileSize; i += _partSize) {
      if (task.isCancelled || hasError) break;
      while (activeDownloads >= 4 && !hasError && !task.isCancelled) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      if (task.isCancelled || hasError) break;

      activeDownloads++;
      int end = (i + _partSize - 1 < fileSize) ? i + _partSize - 1 : fileSize - 1;
      int pNum = (i / _partSize).floor() + 1;

        allTasks.add(downloadPart(i, end, pNum).then((_) => activeDownloads--).catchError((e) {
        hasError = true; errorMsg = e.toString(); activeDownloads--;
        return 0;
      }));
    }

    await Future.wait(allTasks);
    await raf.close(); // 关闭流

    if (task.isCancelled) { file.deleteSync(); throw Exception("用户取消"); }
    if (hasError) { file.deleteSync(); throw Exception(errorMsg); }
  }

  Future<void> uploadFile(String localPath, String remoteKey, TransferTask task) async {
    if (!isConfigured) return;
    final cleanKey = _sanitizeKey(remoteKey);
    final file = File(localPath);
    final fileSize = await file.length();

    if (fileSize <= _partSize) {
      final bytes = await file.readAsBytes();
      await _uploadSingleFile(cleanKey, bytes);
      task.complete(null);
    } else {
      await _uploadMultipartFile(file, cleanKey, fileSize, task);
    }
  }

  /// [核心新增] OSCA > 100M 多分片上传支持
  // ====================[终极安全版] 彻底根除暗箱头与签名 403 陷阱 ====================
  Future<void> _uploadMultipartFile(File file, String key, int fileSize, TransferTask task) async {
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(key);

    final initHeaders = S3Signer.generateV4Headers(method: 'POST', host: host, path: path, queryParams: {'uploads': ''}, ak: _ak!, sk: _sk!);
    final initRes = await http.post(Uri.parse('$_endpoint$path?uploads='), headers: initHeaders);
    if (initRes.statusCode != 200) throw Exception("初始化分片失败: ${initRes.body}");
    
    // 兼容部分 S3 服务端返回标签大小写不一致的问题
    final match = RegExp(r'<[Uu]ploadId>(.*?)</[Uu]ploadId>').firstMatch(initRes.body);
    if (match == null) throw Exception("无法获取 UploadId");
    final uploadId = match.group(1)!;

    List<Map<String, dynamic>> uploadedParts =[];
    int totalUploadedBytes = 0;
    final overallStartTime = DateTime.now().millisecondsSinceEpoch;

    void onBytesSent(int bytesCount) {
      totalUploadedBytes += bytesCount;
      final elapsedSecs = (DateTime.now().millisecondsSinceEpoch - overallStartTime) / 1000.0;
      final speed = elapsedSecs > 0 ? '${formatSize(totalUploadedBytes / elapsedSecs)}/s' : '...';
      task.updateOverall(totalUploadedBytes / fileSize.toDouble(), speed);
    }

    int activeUploads = 0;
    List<Future<void>> allTasks =[];
    bool hasError = false;
    String errorMsg = "";

    // 内存控制：死死压住最多只有 4x5MB = 20MB 在内存中
    final raf = await file.open(mode: FileMode.read);
    int partNumber = 1;

    try {
      while (true) {
        if (task.isCancelled || hasError) break;

        while (activeUploads >= 4 && !hasError && !task.isCancelled) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
        if (task.isCancelled || hasError) break;

        final chunkBytes = await raf.read(_partSize);
        if (chunkBytes.isEmpty) break; // 读取完毕

        activeUploads++;
        final pNum = partNumber++;

        final future = _sendPart(chunkBytes, pNum, uploadId, path, host, uploadedParts, task, onBytesSent)
            .then((_) => activeUploads--)
            .catchError((e) {
               hasError = true; errorMsg = e.toString(); activeUploads--;
            });

        allTasks.add(future);
      }
      await Future.wait(allTasks);
    } finally {
      await raf.close();
    }

    if (task.isCancelled) throw Exception("用户取消");
    if (hasError) throw Exception(errorMsg);

    uploadedParts.sort((a, b) => (a['PartNumber'] as int).compareTo(b['PartNumber'] as int));
    final completeXml = _buildCompleteXml(uploadedParts);
    final completeBytes = utf8.encode(completeXml);
    
    final completeHeaders = S3Signer.generateV4Headers(method: 'POST', host: host, path: path, queryParams: {'uploadId': uploadId}, ak: _ak!, sk: _sk!, payloadBytes: completeBytes);
    final completeRes = await http.post(Uri.parse('$_endpoint$path?uploadId=$uploadId'), headers: completeHeaders, body: completeBytes);
    if (completeRes.statusCode != 200) throw Exception("合并分片失败: ${completeRes.body}");
  }

  String _buildCompleteXml(List<Map<String, dynamic>> parts) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">');
    for (final part in parts) {
      buffer.writeln('  <Part>');
      buffer.writeln('    <PartNumber>${part['PartNumber']}</PartNumber>');
      buffer.writeln('    <ETag>${part['ETag']}</ETag>');
      buffer.writeln('  </Part>');
    }
    buffer.writeln('</CompleteMultipartUpload>');
    return buffer.toString();
  }

  Future<void> _uploadSingleFile(String key, Uint8List data) async {
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(key);
    
    final headers = S3Signer.generateV4Headers(
      method: 'PUT',
      host: host,
      path: path,
      ak: _ak!,
      sk: _sk!,
      payloadBytes: data,
    );

    final response = await http.put(Uri.parse('$_endpoint$path'), headers: headers, body: data);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception("上传失败: ${response.statusCode} - ${response.body}");
    }
  }

  Future<void> _sendPart(Uint8List chunkBytes, int pNum, String uploadId, String path, String host, List<Map<String, dynamic>> uploadedParts, TransferTask task, Function(int) onBytesSent) async {
    const int maxRetries = 3;
    final safeUploadId = S3Signer.uriEncode(uploadId);
    final queryParams = {'partNumber': pNum.toString(), 'uploadId': uploadId};

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      if (task.isCancelled) return;
      int sentBytesThisAttempt = 0;
      final client = http.Client();

      try {
        task.updatePart(pNum, 0.0, attempt > 1 ? '重试($attempt/3)' : '发送中...');

        final extraHeaders = {
          'Content-Type': 'application/octet-stream',
        };

        final headers = S3Signer.generateV4Headers(
          method: 'PUT', 
          host: host, 
          path: path, 
          queryParams: queryParams,
          extraHeaders: extraHeaders,
          ak: _ak!, 
          sk: _sk!, 
          payloadBytes: chunkBytes
        );

        final url = Uri.parse('$_endpoint$path?partNumber=$pNum&uploadId=$safeUploadId');
        final request = http.StreamedRequest('PUT', url);
        request.headers.addAll(headers);
        request.contentLength = chunkBytes.length;

        final startT = DateTime.now().millisecondsSinceEpoch;

        // 使用 async* 配合较小的 chunk 实现流式进度更新，依靠底层机制控制速率
        Stream<List<int>> streamData() async* {
          const chunkSize = 128 * 1024;
          for (int i = 0; i < chunkBytes.length; i += chunkSize) {
            if (task.isCancelled) throw Exception("任务取消");
            int end = (i + chunkSize < chunkBytes.length) ? i + chunkSize : chunkBytes.length;
            final piece = chunkBytes.sublist(i, end);
            
            yield piece;
            
            sentBytesThisAttempt += piece.length;
            onBytesSent(piece.length); 
            
            double elapsed = (DateTime.now().millisecondsSinceEpoch - startT) / 1000.0;
            task.updatePart(pNum, sentBytesThisAttempt / chunkBytes.length, elapsed > 0 ? '${formatSize(sentBytesThisAttempt / elapsed)}/s' : '...');
          }
        }

        final responseFuture = client.send(request);
        
        await request.sink.addStream(streamData());
        request.sink.close();

        final streamedResponse = await responseFuture.timeout(const Duration(minutes: 5));
        final response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode != 200) {
          String errMsg = response.body;
          final match = RegExp(r'<Code>(.*?)</Code>').firstMatch(errMsg);
          if (match != null) errMsg = match.group(1)!;
          throw Exception("${response.statusCode} - $errMsg");
        }

        String? etag = response.headers['etag'] ?? response.headers['ETag'];
        if (etag == null || etag.isEmpty) {
          final match = RegExp(r'<ETag>(.*?)</ETag>', caseSensitive: false).firstMatch(response.body);
          etag = match?.group(1);
        }
        if (etag == null || etag.isEmpty) throw Exception("缺失 ETag");
        etag = etag.replaceAll('"', '');

        uploadedParts.add({'PartNumber': pNum, 'ETag': etag});
        task.updatePart(pNum, 1.0, '完成');
        return;

      } catch (e) {
        onBytesSent(-sentBytesThisAttempt);
        
        if (task.isCancelled) return;
        
        String uiErrorText = e.toString().replaceAll('Exception: ', '');
        if (uiErrorText.length > 15) uiErrorText = uiErrorText.substring(0, 15) + '...';
        
        if (attempt == maxRetries) {
          task.updatePart(pNum, 0.0, '失败');
          throw Exception("分片 $pNum 异常: $e");
        }
        
        task.updatePart(pNum, 0.0, uiErrorText);
        await Future.delayed(Duration(seconds: attempt * 2));
      } finally {
        client.close();
      }
    }
  }

  // --- [新增]: 重命名/移动文件 (复制 + 删除) ---
  Future<void> moveFile(String oldKey, String newKey) async {
    if (!isConfigured) return;
    final cleanOld = _sanitizeKey(oldKey);
    final cleanNew = _sanitizeKey(newKey);
    
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(cleanNew);
    
    // AWS 要求 x-amz-copy-source 必须包含 /bucket/，并且 URL 编码
    final copySource = '/${_bucket!}/${S3Signer.uriEncode(cleanOld)}';
    
    final headers = S3Signer.generateV4Headers(
      method: 'PUT',
      host: host,
      path: path,
      ak: _ak!,
      sk: _sk!,
      extraHeaders: {'x-amz-copy-source': copySource},
    );
    
    // 1. 发起复制请求
    final response = await http.put(Uri.parse('$_endpoint$path'), headers: headers);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception("移动/重命名失败: ${response.statusCode} - ${utf8.decode(response.bodyBytes)}");
    }
    
    // 2. 复制成功后删除原文件
    await _deleteSingleItem(cleanOld, false);
  }
}
