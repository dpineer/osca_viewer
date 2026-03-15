import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 's3_signer.dart';

// [新增]：任务取消令牌
class TransferTask {
  bool isCancelled = false;
  void cancel() => isCancelled = true;
}

// [新增]：智能单位转换
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


  Future<void> deleteItem(String key, bool isDir) async {
    if (!isConfigured) return;
    final cleanKey = _sanitizeKey(key);

    if (isDir) {
      // 【核心修复】：S3的文件夹需要带上尾部斜杠，否则会误删前缀相似的其他文件
      final dirPrefix = cleanKey.endsWith('/') ? cleanKey : '$cleanKey/';
      final items = await listFiles(dirPrefix);
      
      // 递归先删除文件夹内部的内容
      for (final item in items) {
        await deleteItem(item['key']!, item['isDir']);
      }
      // 内部文件清空后，必须删除文件夹自身的0字节标记对象，否则它在列表中永远存在
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


  // ==================== [新增] 云端虚拟文件夹 VFS ====================
  // 读取虚拟文件夹配置
  Future<List<String>> _getVFSFolders() async {
    try {
      final host = Uri.parse(_endpoint!).host;
      final path = _encodePath('.osca_vfs.json');
      final headers = S3Signer.generateV4Headers(method: 'GET', host: host, path: path, ak: _ak!, sk: _sk!);
      final res = await http.get(Uri.parse('$_endpoint$path'), headers: headers);
      if (res.statusCode == 200) {
        final map = jsonDecode(utf8.decode(res.bodyBytes));
        return List<String>.from(map['folders'] ?? []);
      }
    } catch (_) {}
    return[];
  }

  // 保存虚拟文件夹配置
  Future<void> _saveVFSFolders(List<String> folders) async {
    final payload = utf8.encode(jsonEncode({'folders': folders.toSet().toList()}));
    await _uploadSingleFile('.osca_vfs.json', Uint8List.fromList(payload));
  }

  // 改造原有的创建文件夹方法
  Future<void> createFolder(String currentPrefix, String folderName) async {
    if (!isConfigured) return;
    final cleanPrefix = _sanitizeKey(currentPrefix);
    String newKey = cleanPrefix + folderName;
    if (!newKey.endsWith('/')) newKey += '/';
    
    // 更新云端 VFS 配置
    final folders = await _getVFSFolders();
    folders.add(newKey);
    await _saveVFSFolders(folders);
  }

  // ==================== 改造获取列表 ====================
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

    // 建议 Query 参数按字母排序拼接，防止偶发签名错误
    final sortedKeys = queryParams.keys.toList()..sort();
    final queryParts = sortedKeys.map((k) => '${S3Signer.uriEncode(k)}=${S3Signer.uriEncode(queryParams[k]!)}');
    final url = '$_endpoint$path?${queryParts.join('&')}';
    
    final response = await http.get(Uri.parse(url), headers: headers);

    if (response.statusCode != 200) throw Exception("列出文件失败: ${response.statusCode}");

    // 【核心修复】：必须使用 utf8 解码 bodyBytes，否则中文文件名会被强制转为 Latin-1 乱码导致 404！
    final responseBody = utf8.decode(response.bodyBytes);

    List<Map<String, dynamic>> items =[];
    final commonPrefixes = RegExp(r'<CommonPrefixes><Prefix>(.*?)</Prefix></CommonPrefixes>')
        .allMatches(responseBody).map((m) => m.group(1)!).toList();
    final contentsMatches = RegExp(r'<Contents>.*?<Key>(.*?)</Key>.*?<Size>(\d+)</Size>.*?<LastModified>(.*?)</LastModified>.*?</Contents>', dotAll: true)
        .allMatches(responseBody);

    for (final prefix in commonPrefixes) {
      final name = prefix.replaceAll(cleanPrefix, '').replaceAll('/', '');
      if (name.isNotEmpty) items.add({'name': name, 'isDir': true, 'size': 0, 'key': prefix});
    }

    for (final m in contentsMatches) {
      final key = m.group(1)!;
      final size = m.group(2)!;
      final time = m.group(3)!;
      final name = key.replaceAll(cleanPrefix, '');
      
      // 过滤掉当前目录自身的空对象标记
      if (key != cleanPrefix && name.isNotEmpty) {
        items.add({'name': name, 'isDir': false, 'size': int.parse(size), 'key': key, 'time': time});
      }
    }
    
    //[在此处追加 VFS 虚拟文件夹解析合并]:
    final vfsFolders = await _getVFSFolders();
    for (final f in vfsFolders) {
      if (f.startsWith(cleanPrefix) && f != cleanPrefix) {
        final relative = f.substring(cleanPrefix.length);
        final name = relative.split('/').firstWhere((e) => e.isNotEmpty, orElse: () => '');
        if (name.isNotEmpty && !items.any((e) => e['name'] == name && e['isDir'])) {
          items.add({'name': name, 'isDir': true, 'size': 0, 'key': cleanPrefix + name + '/'});
        }
      }
    }
    
    // 过滤掉我们存放的系统级配置文件，不让用户看到
    items.removeWhere((e) => e['name'] == '.osca_vfs.json');
    return items;
  }

  // ==================== 改造下载，支持取消和计算网速 ====================
  Future<void> downloadFile(String key, String localPath, TransferTask task, Function(double, String) onProgress) async {
    if (!isConfigured) return;
    final cleanKey = _sanitizeKey(key);
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(cleanKey);
    
    final headers = S3Signer.generateV4Headers(method: 'GET', host: host, path: path, ak: _ak!, sk: _sk!);
    final request = http.Request('GET', Uri.parse('$_endpoint$path'))..headers.addAll(headers);
    
    // 使用 Client 来保持连接以读取 stream
    final client = http.Client();
    final response = await client.send(request);

    if (response.statusCode != 200) throw Exception("下载失败: ${response.statusCode}");

    final file = File(localPath);
    final sink = file.openWrite();
    final totalSize = response.contentLength ?? 0;
    int downloadedSize = 0;
    final startTime = DateTime.now().millisecondsSinceEpoch;

    try {
      await for (final chunk in response.stream) {
        if (task.isCancelled) {
          throw Exception("用户已取消任务");
        }
        sink.add(chunk);
        downloadedSize += chunk.length;
        
        final elapsedSecs = (DateTime.now().millisecondsSinceEpoch - startTime) / 1000.0;
        final speed = elapsedSecs > 0 ? '${formatSize(downloadedSize / elapsedSecs)}/s' : '计算中...';
        
        if (totalSize > 0) onProgress(downloadedSize / totalSize.toDouble(), speed);
      }
    } finally {
      await sink.close();
      client.close(); // 释放资源
      if (task.isCancelled && file.existsSync()) file.deleteSync(); // 取消时清理碎片
    }
  }

  // ==================== 改造上传，支持取消和计算网速 ====================
  Future<void> uploadFile(String localPath, String remoteKey, TransferTask task, Function(double, String) onProgress) async {
    if (!isConfigured) return;
    final cleanKey = _sanitizeKey(remoteKey);
    final file = File(localPath);
    final fileSize = await file.length();

    if (fileSize <= _partSize) {
      final bytes = await file.readAsBytes();
      await _uploadSingleFile(cleanKey, bytes);
      onProgress(1.0, '完成');
    } else {
      await _uploadMultipartFile(file, cleanKey, fileSize, task, onProgress);
    }
  }

  /// [核心新增] OSCA > 100M 多分片上传支持
  Future<void> _uploadMultipartFile(File file, String key, int fileSize, TransferTask task, Function(double, String) onProgress) async {
    final host = Uri.parse(_endpoint!).host;
    final path = _encodePath(key);

    // 1. Initiate
    final initQueryParams = {'uploads': ''};
    final initHeaders = S3Signer.generateV4Headers(
      method: 'POST', host: host, path: path, queryParams: initQueryParams, ak: _ak!, sk: _sk!,
    );
    final initRes = await http.post(Uri.parse('$_endpoint$path?uploads='), headers: initHeaders);
    if (initRes.statusCode != 200) throw Exception("初始化分片失败");
    final uploadId = RegExp(r'<UploadId>(.*?)</UploadId>').firstMatch(initRes.body)!.group(1)!;

    // 2. Upload Parts
    List<Map<String, dynamic>> uploadedParts =[];
    int uploadedBytes = 0;
    int partNumber = 1;
    List<int> currentChunk =[];
    
    final startTime = DateTime.now().millisecondsSinceEpoch;
    await for (final chunk in file.openRead()) {
      if (task.isCancelled) throw Exception("已取消上传");
      currentChunk.addAll(chunk);
      while (currentChunk.length >= _partSize) {
        final chunkBytes = Uint8List.fromList(currentChunk.sublist(0, _partSize));
        currentChunk = currentChunk.sublist(_partSize);
        await _sendPart(chunkBytes, partNumber, uploadId, path, host, uploadedParts);
        uploadedBytes += chunkBytes.length;
        final elapsedSecs = (DateTime.now().millisecondsSinceEpoch - startTime) / 1000.0;
        final speed = elapsedSecs > 0 ? '${formatSize(uploadedBytes / elapsedSecs)}/s' : '计算中...';
        onProgress(uploadedBytes / fileSize, speed);
        partNumber++;
      }
    }
    if (currentChunk.isNotEmpty) {
      final chunkBytes = Uint8List.fromList(currentChunk);
      await _sendPart(chunkBytes, partNumber, uploadId, path, host, uploadedParts);
      uploadedBytes += chunkBytes.length;
      final elapsedSecs = (DateTime.now().millisecondsSinceEpoch - startTime) / 1000.0;
      final speed = elapsedSecs > 0 ? '${formatSize(uploadedBytes / elapsedSecs)}/s' : '计算中...';
      onProgress(uploadedBytes / fileSize, speed);
    }

    // 3. Complete
    final completeXml = _buildCompleteXml(uploadedParts);
    final completeXmlBytes = utf8.encode(completeXml);
    final completeHeaders = S3Signer.generateV4Headers(
      method: 'POST', host: host, path: path, queryParams: {'uploadId': uploadId}, ak: _ak!, sk: _sk!, payloadBytes: completeXmlBytes,
    );
    final completeRes = await http.post(Uri.parse('$_endpoint$path?uploadId=$uploadId'), headers: completeHeaders, body: completeXmlBytes);
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

  Future<void> _sendPart(Uint8List chunkBytes, int partNumber, String uploadId, String path, String host, List<Map<String, dynamic>> uploadedParts) async {
    final queryParams = {'partNumber': partNumber.toString(), 'uploadId': uploadId};
    final headers = S3Signer.generateV4Headers(
      method: 'PUT', host: host, path: path, queryParams: queryParams, ak: _ak!, sk: _sk!, payloadBytes: chunkBytes,
    );
    final url = '$_endpoint$path?partNumber=$partNumber&uploadId=$uploadId';
    final partRes = await http.put(Uri.parse(url), headers: headers, body: chunkBytes);
    if (partRes.statusCode != 200) throw Exception("分片 $partNumber 上传失败");
    
    final etag = partRes.headers['etag'] ?? partRes.headers['ETag'];
    uploadedParts.add({'PartNumber': partNumber, 'ETag': etag});
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
