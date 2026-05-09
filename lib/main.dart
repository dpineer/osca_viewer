import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'services/s3_storage_service.dart';


void main() {
  runApp(
    // 替换原来的 ChangeNotifierProvider 为 MultiProvider
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => S3StorageService()),
        ChangeNotifierProvider(create: (_) => TransferManager()), // [新增]
      ],
      child: MyApp(),
    ),
  );
}

// 新增：主题状态管理类
class ThemeProvider extends ChangeNotifier {
  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool('isDarkMode') ?? false;
    notifyListeners();
  }

  Future<void> toggleTheme(bool value) async {
    _isDarkMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', value);
  }
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // 监听主题变化
    final themeProvider = context.watch<ThemeProvider>();
    
    return MaterialApp(
      title: 'OSCA Viewer',
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      // 动态切换主题
      themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: const AuthWrapper(),
    );
  }
}

// 修改点2: 新增路由分发组件
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final service = context.watch<S3StorageService>();
    // 等待 SharedPreferences 加载完毕
    if (!service.isInit) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // 根据是否配置过信息自动选择跳转
    return service.isConfigured ? FileBrowserPage() : ConfigPage();
  }
}

class ConfigPage extends StatefulWidget {
  @override
  _ConfigPageState createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  final TextEditingController _akController = TextEditingController();
  final TextEditingController _skController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _bucketController = TextEditingController();
  bool _isLoading = false;
  int? _linkExpireSeconds = 86400; // 默认一天，null 表示31年
  final TextEditingController _customDaysController = TextEditingController();
  final TextEditingController _customHoursController = TextEditingController();
  bool _isCustomSelected = false; // 标记当前是否处于自定义选中状态
  // 预设的固定选项值（秒）
  static const List<int> _fixedExpireOptions = [3600, 86400, 604800];
  // 自定义和31年用特殊值标记
  static const int _customFlag = -1;
  static const int _infiniteFlag = -2;

  @override
  void initState() {
    super.initState();
    _loadExistingConfig(); // 初始化时读取已有配置
  }

  // 新增：读取本地配置并赋值给输入框
  Future<void> _loadExistingConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _akController.text = prefs.getString('ak') ?? '';
        _skController.text = prefs.getString('sk') ?? '';
        _endpointController.text = prefs.getString('endpoint') ?? '';
        _bucketController.text = prefs.getString('bucket') ?? '';
        final stored = prefs.getInt('link_expire_seconds');
        if (stored == null || stored == -1) {
          // -1 表示31年时间
          _linkExpireSeconds = null;
        } else {
          _linkExpireSeconds = stored;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('配置 S3 连接'),
      ),
      body: SingleChildScrollView( // 加上滚动以防键盘遮挡
        padding: EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _akController,
              decoration: InputDecoration(
                labelText: 'Access Key',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _skController,
              decoration: InputDecoration(
                labelText: 'Secret Key',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            SizedBox(height: 16),
            TextField(
              controller: _endpointController,
              decoration: InputDecoration(
                labelText: 'Endpoint',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _bucketController,
              decoration: InputDecoration(
                labelText: 'Bucket',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 24),
            SizedBox(
              width: double.infinity, // 按钮加宽
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _connect,
                child: _isLoading 
                    ? CircularProgressIndicator()
                    : Text('连接并保存', style: TextStyle(fontSize: 16)),
              ),
            ),
            Divider(height: 40),
            // 新增：暗黑模式切换按钮
            SwitchListTile(
              title: Text('暗夜模式', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('跟随系统或手动切换深色主题'),
              secondary: Icon(Icons.dark_mode),
              value: context.watch<ThemeProvider>().isDarkMode,
              onChanged: (value) {
                context.read<ThemeProvider>().toggleTheme(value);
              },
            ),
            Divider(height: 40),
            
            // [增强]：外链有效期配置（支持自定义和31年）
            ListTile(
              title: Text('分享外链有效期'),
              subtitle: Text('影响通过APP复制出的分享直链存活时间'),
              trailing: DropdownButton<int>(
                value: _linkExpireSeconds ?? _infiniteFlag,
                items: [
                  DropdownMenuItem(value: 3600, child: Text('1 小时')),
                  DropdownMenuItem(value: 86400, child: Text('1 天')),
                  DropdownMenuItem(value: 604800, child: Text('7 天')),
                  DropdownMenuItem(value: _customFlag, child: Text('自定义...')),
                  DropdownMenuItem(value: _infiniteFlag, child: Text('31年')),
                ],
                onChanged: (val) {
                  if (val == null) return;
                  if (val == _customFlag) {
                    _showCustomTimeDialog();
                  } else if (val == _infiniteFlag) {
                    setState(() => _linkExpireSeconds = null);
                  } else {
                    setState(() => _linkExpireSeconds = val);
                  }
                },
              ),
            ),
            
            // [新增]：分享管理按钮
            ListTile(
              leading: Icon(Icons.link, color: Colors.green),
              title: Text('分享链接管理'),
              subtitle: Text('查看和管理已生成的分享外链'),
              trailing: Icon(Icons.arrow_forward_ios),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => ShareManagerPage())),
            ),
            
            // [更新]：修改为 Native S3 目录机制说明
            ListTile(
              leading: Icon(Icons.info_outline, color: Colors.blue),
              title: Text('标准 S3 目录架构', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                '已接入 OSCA 官方规范：通过创建以 "/" 结尾的 0 字节对象来实现原生目录管理。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _connect() async {
    if (_akController.text.isEmpty || _skController.text.isEmpty ||
        _endpointController.text.isEmpty || _bucketController.text.isEmpty) {
      _showMsg("请填写所有字段", isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 保存成功后，最外层的 AuthWrapper 会自动监听到状态改变并切换页面
      await context.read<S3StorageService>().connect(
        _akController.text, _skController.text,
        _endpointController.text, _bucketController.text,
      );
      
      final prefs = await SharedPreferences.getInstance();
      // null 表示31年时间，存储为 -1
      await prefs.setInt('link_expire_seconds', _linkExpireSeconds ?? -1);
      
      // 如果是从文件列表的"设置"图标 push 进来的，认证成功后要 pop 退出
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } catch (e) {
      _showMsg("连接失败: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // [新增]：弹出自定义时间输入框
  Future<void> _showCustomTimeDialog() async {
    _customDaysController.clear();
    _customHoursController.clear();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('自定义外链有效期'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _customDaysController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '天数',
                hintText: '0',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: _customHoursController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '小时',
                hintText: '0',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 8),
            Text(
              '总有效期为 ${_customDaysController.text.isEmpty ? 0 : int.tryParse(_customDaysController.text) ?? 0} 天 '
              '${_customHoursController.text.isEmpty ? 0 : int.tryParse(_customHoursController.text) ?? 0} 小时',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消')),
          ElevatedButton(
            onPressed: () {
              final days = int.tryParse(_customDaysController.text) ?? 0;
              final hours = int.tryParse(_customHoursController.text) ?? 0;
              final totalSeconds = days * 86400 + hours * 3600;
              if (totalSeconds < 60) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('有效期至少为 1 分钟'), backgroundColor: Colors.red),
                );
                return;
              }
              Navigator.pop(ctx, totalSeconds);
            },
            child: Text('确认'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      setState(() => _linkExpireSeconds = result);
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  void dispose() {
    _akController.dispose();
    _skController.dispose();
    _endpointController.dispose();
    _bucketController.dispose();
    super.dispose();
  }
}

class FileBrowserPage extends StatefulWidget {
  @override
  _FileBrowserPageState createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  String _currentPrefix = '';
  List<Map<String, dynamic>> _files =[];
  bool _isLoading = false;
  
  // [新增]: 搜索状态
  bool _isSearching = false;
  String _searchQuery = '';

  // ================= [新增] 状态层：批量操作支持 =================
  bool _isSelectMode = false; // 是否处于多选模式
  Set<String> _selectedFiles = {}; // 已选中的文件 key 集合

  // [新增]: 本地过滤当前目录文件
  List<Map<String, dynamic>> get _filteredFiles {
    if (_searchQuery.isEmpty) return _files;
    return _files.where((item) => 
      item['name'].toString().toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }
  
  // ... 保留现有的 initState 和 _loadFiles, _handleDownload 等方法 ...

  // [新增]: 新建文件夹弹窗
  Future<void> _handleCreateFolder() async {
    final nameCtrl = TextEditingController();
    bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('新建文件夹'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: InputDecoration(hintText: '请输入文件夹名称'),
        ),
        actions:[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('创建')),
        ],
      )
    );

    if (confirm == true && nameCtrl.text.trim().isNotEmpty) {
      setState(() => _isLoading = true);
      try {
        await context.read<S3StorageService>().createFolder(_currentPrefix, nameCtrl.text.trim());
        _showMsg("创建成功");
        _loadFiles();
      } catch (e) {
        _showMsg("创建失败: $e", isError: true);
        setState(() => _isLoading = false);
      }
    }
  }

  // [新增]: 属性与移动/重命名弹窗
  void _showPropertiesDialog(Map<String, dynamic> item) {
    final nameCtrl = TextEditingController(text: item['name']);
    final pathCtrl = TextEditingController(text: _currentPrefix); // 默认当前路径

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('属性与编辑'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('文件类型: ${item['isDir'] ? '文件夹' : '文件'}', style: TextStyle(fontWeight: FontWeight.bold)),
              if (!item['isDir']) Text('大小: ${(item['size'] / 1024).toStringAsFixed(2)} KB'),
              if (!item['isDir'] && item['time'] != null) Text('修改时间: ${item['time']}'),
              SizedBox(height: 16),
              
              if (!item['isDir']) ...[
                TextField(controller: nameCtrl, decoration: InputDecoration(labelText: '重命名', border: OutlineInputBorder())),
                SizedBox(height: 10),
                TextField(controller: pathCtrl, decoration: InputDecoration(labelText: '所属路径 (例如 folder/)', border: OutlineInputBorder())),
                SizedBox(height: 8),
                Text('⚠️ 提示：修改路径或名称将触发复制并删除原文件', style: TextStyle(fontSize: 12, color: Colors.orange)),
              ] else ...[
                Text('⚠️ 提示：S3 架构不支持直接重命名文件夹，如有需要请新建文件夹后移动内部文件。', style: TextStyle(color: Colors.grey)),
              ]
            ],
          ),
        ),
        actions:[
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('关闭')),
          if (!item['isDir'])
            ElevatedButton(
              onPressed: () async {
                final newKey = pathCtrl.text.trim() + nameCtrl.text.trim();
                if (newKey != item['key']) {
                  Navigator.pop(ctx);
                  setState(() => _isLoading = true);
                  try {
                    await context.read<S3StorageService>().moveFile(item['key'], newKey);
                    _showMsg("修改成功");
                    _loadFiles();
                  } catch (e) {
                    _showMsg(e.toString(), isError: true);
                    setState(() => _isLoading = false);
                  }
                } else {
                  Navigator.pop(ctx);
                }
              }, 
              child: Text('保存更改')
            )
        ],
      )
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadFiles();
    });
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final service = context.read<S3StorageService>();
      if (!service.isConfigured) {
        _showMsg("请先配置S3连接参数", isError: true);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => ConfigPage()),
        );
        return;
      }
      final files = await service.listFiles(_currentPrefix);
      if (mounted) {
        setState(() {
          _files = files;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      _showMsg("加载文件失败: $e", isError: true);
    }
  }

  // ================= [新增] 下载引擎：公共路径选择器 =================
  Future<String?> _pickDownloadDirectory() async {
    if (Platform.isAndroid) {
      Directory? dir = await getExternalStorageDirectory();
      return dir?.path ?? (await getApplicationDocumentsDirectory()).path;
    } else if (Platform.isIOS) {
      Directory dir = await getApplicationDocumentsDirectory();
      return dir.path;
    } else {
      // 桌面端 (包括您的 Debian Linux 环境) 调用系统目录选择器
      return await FilePicker.platform.getDirectoryPath();
    }
  }

  // ================= [重构] 下载引擎：基础单文件下载 =================
  Future<void> _handleDownload(Map<String, dynamic> item) async {
    if (item['isDir']) {
      _showMsg("暂不支持直接下载整个文件夹", isError: true);
      return;
    }

    String? localDir = await _pickDownloadDirectory();
    if (localDir == null) return;

    String localPath = p.join(localDir, item['name']);
    final task = TransferTask(item['name'], isUpload: false);
    context.read<TransferManager>().addTask(task);
    _showMsg("已加入并发下载队列");

    _performDownload(item['key'], localPath, item['size'], task);
  }

  // ================= [新增] 下载引擎：批量多选并发下载 =================
  Future<void> _handleBatchDownload() async {
    final itemsToDownload = _filteredFiles.where((f) => _selectedFiles.contains(f['key']) && !f['isDir']).toList();
    if (itemsToDownload.isEmpty) {
      _showMsg("请选择包含非文件夹的文件", isError: true);
      return;
    }

    // 批量下载只需要选择一次保存目录
    String? localDir = await _pickDownloadDirectory();
    if (localDir == null) return;

    for (var item in itemsToDownload) {
      String localPath = p.join(localDir, item['name']);
      final task = TransferTask(item['name'], isUpload: false);
      context.read<TransferManager>().addTask(task);
      
      // 注入并发执行流
      _performDownload(item['key'], localPath, item['size'], task);
    }

    _showMsg("已将 ${itemsToDownload.length} 个文件加入并发下载队列");
    setState(() {
      _isSelectMode = false;
      _selectedFiles.clear();
    });
  }

  // 后台独立执行的下载任务单元
  Future<void> _performDownload(String key, String localPath, int size, TransferTask task) async {
    try {
      await context.read<S3StorageService>().downloadFile(key, localPath, size, task);
      if (!task.isCancelled) task.complete((t) => context.read<TransferManager>().removeTask(t));
    } catch (e) {
      if (!task.isCancelled) task.error(e.toString());
    }
  }

  // ================= [重构] 上传引擎：支持多文件极速并发 =================
  Future<void> _handleUpload() async {
    // 开启多文件选择 (allowMultiple: true)
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    int addedCount = 0;
    for (var file in result.files) {
      if (file.path == null) continue;
      String localPath = file.path!;
      String fileName = file.name;
      
      final task = TransferTask(fileName, isUpload: true);
      context.read<TransferManager>().addTask(task);
      addedCount++;
      
      // 剥离上传动作，使其在后台非阻塞执行
      _performUpload(localPath, fileName, task);
    }
    
    if (addedCount > 0) {
      _showMsg("已将 $addedCount 个文件加入上传队列，正在后台极速并发上传");
    }
  }

  // 后台独立执行的上传任务单元
  Future<void> _performUpload(String localPath, String fileName, TransferTask task) async {
    try {
      await context.read<S3StorageService>().uploadFile(localPath, "$_currentPrefix$fileName", task);
      if (!task.isCancelled) {
        task.complete((t) => context.read<TransferManager>().removeTask(t));
        // 降低列表高频刷新的开销：如果所有上传任务都已经完成，则刷新列表
        if (mounted && context.read<TransferManager>().activeCount == 0) {
          _loadFiles(); 
        }
      }
    } catch (e) {
      if (!task.isCancelled) task.error(e.toString());
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> _handleDelete(Map<String, dynamic> item) async {
    bool confirm = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认删除'),
        content: Text('确定要删除 ${item['name']} 吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    ) ?? false;

    if (!confirm) return;

    try {
      await context.read<S3StorageService>().deleteItem(item['key'], item['isDir']);
      _showMsg("删除成功");
      _loadFiles();
    } catch (e) {
      _showMsg("删除失败: $e", isError: true);
    }
  }

  // 新增：格式化文件大小显示
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(2)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  // --- 底部弹出的专属任务监控控制台 ---
  void _showTaskCenter() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6, minChildSize: 0.4, maxChildSize: 0.9,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children:[
              Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children:[
                    Text('传输任务中心', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(icon: Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ),
              Expanded(
                child: Consumer<TransferManager>(
                  builder: (context, manager, _) => ListView.builder(
                    controller: controller,
                    itemCount: manager.tasks.length,
                    itemBuilder: (context, index) {
                      final task = manager.tasks[index];
                      // 局部监听单个任务的状态更新
                      return ChangeNotifierProvider.value(
                        value: task, 
                        child: Consumer<TransferTask>(
                          builder: (ctx, t, _) => Card(
                            margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children:[
                                  Row(
                                    children:[
                                      Icon(t.isUpload ? Icons.upload : Icons.download, size: 20, color: Colors.blue),
                                      SizedBox(width: 8),
                                      Expanded(child: Text(t.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold))),
                                      if (!t.isFinished && !t.isCancelled && !t.isError)
                                        IconButton(icon: Icon(Icons.cancel, color: Colors.red, size: 20), onPressed: t.cancel, constraints: BoxConstraints())
                                      else
                                        Text(t.isFinished ? '完成' : (t.isError ? '失败' : '取消'), style: TextStyle(color: t.isFinished ? Colors.green : Colors.red, fontSize: 12)),
                                    ],
                                  ),
                                  SizedBox(height: 8),
                                  LinearProgressIndicator(value: t.overallProgress),
                                  SizedBox(height: 4),
                                  Text('${(t.overallProgress * 100).toStringAsFixed(1)}% - ${t.overallSpeed}', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                  
                                  // === 微观视角：多轨道分段进度监控 ===
                                  if (t.isUpload && t.parts.isNotEmpty) ...[
                                    Divider(),
                                    Text('多车道并发引擎状态:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                                    SizedBox(height: 6),
                                    Wrap(
                                      spacing: 8, runSpacing: 8,
                                      // [修复卡顿]: 仅渲染 visibleParts
                                      children: t.visibleParts.map((p) => 
                                        Container(
                                          width: 80, padding: EdgeInsets.all(6),
                                          decoration: BoxDecoration(color: Colors.grey.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                                          child: Column(
                                            children:[
                                              Text('分片 ${p.partNumber}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                              SizedBox(height: 4),
                                              LinearProgressIndicator(value: p.progress, minHeight: 3),
                                              SizedBox(height: 2),
                                              Text(p.speed, style: TextStyle(fontSize: 9, color: Colors.grey)),
                                            ]
                                          )
                                        )
                                      ).toList()
                                    )
                                  ]
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        )
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // [重构] 动态 AppBar：根据是否进入批量选择模式渲染不同的顶部栏
      appBar: _isSelectMode
        ? AppBar(
            leading: IconButton(
              icon: Icon(Icons.close),
              onPressed: () {
                setState(() {
                  _isSelectMode = false;
                  _selectedFiles.clear();
                });
              },
            ),
            title: Text('已选择 ${_selectedFiles.length} 项'),
            actions:[
              IconButton(
                icon: Icon(Icons.download),
                tooltip: '批量下载',
                onPressed: _selectedFiles.isNotEmpty ? _handleBatchDownload : null,
              ),
              // 若后期需要支持批量删除，可在此处增加 Icons.delete 的入口
            ],
          )
        : AppBar(
            title: _isSearching 
              ? TextField(
                  autofocus: true,
                  style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
                  decoration: InputDecoration(hintText: '搜索当前目录文件...', border: InputBorder.none),
                  onChanged: (val) => setState(() => _searchQuery = val),
                )
              : Text('OSCA - ${_currentPrefix.isEmpty ? '根目录' : _currentPrefix}', style: TextStyle(fontSize: 16)),
            actions:[
              // [新增] 批量操作入口
              IconButton(
                icon: Icon(Icons.checklist),
                tooltip: '批量操作',
                onPressed: () => setState(() => _isSelectMode = true),
              ),
              IconButton(
                icon: Icon(_isSearching ? Icons.close : Icons.search),
                onPressed: () {
                  setState(() {
                    _isSearching = !_isSearching;
                    if (!_isSearching) _searchQuery = ''; 
                  });
                },
              ),
              IconButton(icon: Icon(Icons.create_new_folder), onPressed: _handleCreateFolder),
              IconButton(icon: Icon(Icons.upload), onPressed: _isLoading ? null : _handleUpload),
              Consumer<TransferManager>(
                builder: (context, manager, _) => IconButton(
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children:[
                      Icon(Icons.swap_vert), 
                      if (manager.activeCount > 0)
                        Positioned(
                          right: -4, top: -4,
                          child: CircleAvatar(
                            radius: 7, backgroundColor: Colors.red,
                            child: Text('${manager.activeCount}', style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                          )
                        )
                    ]
                  ),
                  onPressed: () => _showTaskCenter(),
                ),
              ),
              IconButton(
                icon: Icon(Icons.insert_link),
                tooltip: '外链管理',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => ShareManagerPage())),
              ),
              IconButton(
                icon: Icon(Icons.settings),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => ConfigPage())),
              ),
            ],
          ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _filteredFiles.length,
              itemBuilder: (context, index) {
                final item = _filteredFiles[index];
                final bool isSelected = _selectedFiles.contains(item['key']);
                
                // 1. 基础卡片 Widget (增加选中态背板与复选框)
                Widget card = Card(
                  color: isSelected ? Colors.blue.withOpacity(0.1) : null,
                  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    // [新增] 多选模式下展示复选框，文件夹暂不支持批量操作
                    leading: _isSelectMode && !item['isDir']
                      ? Checkbox(
                          value: isSelected,
                          onChanged: (val) {
                            setState(() {
                              if (val == true) _selectedFiles.add(item['key']);
                              else _selectedFiles.remove(item['key']);
                            });
                          },
                        )
                      : Icon(
                          item['isDir'] ? Icons.folder : Icons.insert_drive_file,
                          color: item['isDir'] ? Colors.orange : Colors.blue,
                        ),
                    title: Text(item['name']),
                    subtitle: item['isDir'] ? null : Text(_formatFileSize(item['size'])),
                    // 批量模式下屏蔽单条目的操作按钮区，保持视觉清晰
                    trailing: _isSelectMode ? null : Row(
                      mainAxisSize: MainAxisSize.min,
                      children:[
                        IconButton(
                          icon: Icon(Icons.info_outline, color: Colors.green),
                          tooltip: '属性与编辑',
                          onPressed: () => _showPropertiesDialog(item),
                        ),
                        if (!item['isDir'])
                          IconButton(
                            icon: Icon(Icons.share, color: Colors.purple),
                            tooltip: '分享外链',
                            onPressed: () async {
                              final url = await context.read<S3StorageService>().generateAndSaveShareUrl(item['key'], item['name']);
                              Clipboard.setData(ClipboardData(text: url));
                              _showMsg("专属外链已复制！您可在外链管理中查看");
                            },
                          ),
                        if (!item['isDir'])
                          IconButton(
                            icon: Icon(Icons.download, color: Colors.blue),
                            tooltip: '下载',
                            onPressed: () => _handleDownload(item),
                          ),
                        IconButton(
                          icon: Icon(Icons.delete, color: Colors.red),
                          tooltip: '删除',
                          onPressed: () => _handleDelete(item),
                        ),
                        if (item['isDir'])
                          Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                      ],
                    ),
                    onTap: () {
                      if (_isSelectMode && !item['isDir']) {
                        // 在多选模式下，点击卡片也可切换选中状态
                        setState(() {
                          if (isSelected) _selectedFiles.remove(item['key']);
                          else _selectedFiles.add(item['key']);
                        });
                      } else if (!_isSelectMode && item['isDir']) {
                        // 常规模式下的文件夹跳转
                        setState(() {
                          _currentPrefix = item['key'];
                          _isSearching = false; 
                          _searchQuery = '';
                        });
                        _loadFiles();
                      }
                    },
                    // [新增] 长按快速进入批量选择模式
                    onLongPress: () {
                      if (!_isSelectMode && !item['isDir']) {
                        setState(() {
                          _isSelectMode = true;
                          _selectedFiles.add(item['key']);
                        });
                      }
                    },
                  ),
                );

                // 2. 文件夹作为接收目标 (DragTarget) 不变
                if (item['isDir']) {
                  return DragTarget<Map<String, dynamic>>(
                    onWillAccept: (data) => data != null && !data['isDir'],
                    onAccept: (data) async {
                      setState(() => _isLoading = true);
                      try {
                        String newKey = item['key'] + data['name'];
                        await context.read<S3StorageService>().moveFile(data['key'], newKey);
                        _showMsg("移动成功");
                        _loadFiles();
                      } catch (e) {
                        _showMsg("移动失败: $e", isError: true);
                        setState(() => _isLoading = false);
                      }
                    },
                    builder: (context, candidateData, rejectedData) {
                      return Container(
                        decoration: BoxDecoration(
                          border: candidateData.isNotEmpty ? Border.all(color: Colors.blue, width: 2) : null,
                        ),
                        child: card,
                      );
                    },
                  );
                } 
                // 3. 文件作为可拖拽源 (多选模式下禁用拖动，防止冲突)
                else {
                  return _isSelectMode
                    ? card 
                    : LongPressDraggable<Map<String, dynamic>>(
                        data: item,
                        feedback: Material(
                          elevation: 8,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: EdgeInsets.all(16),
                            decoration: BoxDecoration(color: Colors.blue.withOpacity(0.9), borderRadius: BorderRadius.circular(8)),
                            child: Text('移动: ${item['name']}', style: TextStyle(color: Colors.white)),
                          ),
                        ),
                        childWhenDragging: Opacity(opacity: 0.3, child: card),
                        child: card,
                      );
                }
              },
            ),
      floatingActionButton: _currentPrefix.isNotEmpty
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _currentPrefix = _currentPrefix.substring(0, _currentPrefix.lastIndexOf('/', _currentPrefix.length - 2) + 1);
                  _isSearching = false; 
                  _searchQuery = '';
                  // 返回上层目录时退出选择模式
                  _isSelectMode = false;
                  _selectedFiles.clear();
                });
                _loadFiles();
              },
              child: Icon(Icons.arrow_back),
              tooltip: '返回上级目录',
            )
          : null,
    );
  }
}

// ==================== [优化重构] 外链管理中心 ====================
class ShareManagerPage extends StatefulWidget {
  @override
  _ShareManagerPageState createState() => _ShareManagerPageState();
}

class _ShareManagerPageState extends State<ShareManagerPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<S3StorageService>().loadShareHistory();
    });
  }

  void _clearExpiredLinks() async {
    final s3 = context.read<S3StorageService>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredIndexes = <int>[];
    
    for (int i = 0; i < s3.shareHistory.length; i++) {
      if (s3.shareHistory[i]['expireAt'] < now) expiredIndexes.add(i);
    }
    
    // 从后往前删，避免索引错乱
    for (int i = expiredIndexes.length - 1; i >= 0; i--) {
      await s3.deleteShareRecord(expiredIndexes[i]);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已清理 ${expiredIndexes.length} 个过期链接')));
  }

  // 计算剩余相对时间（31年时间显示"31年有效"）
  String _getRemainingTime(int expireAt) {
    // 如果过期时间在 2050 年之后，视为31年链接
    if (expireAt > DateTime(2050, 1, 1).millisecondsSinceEpoch) {
      return "31年有效";
    }
    final diff = DateTime.fromMillisecondsSinceEpoch(expireAt).difference(DateTime.now());
    if (diff.isNegative) return "已过期";
    if (diff.inDays > 0) return "剩 ${diff.inDays} 天 ${diff.inHours % 24} 小时";
    if (diff.inHours > 0) return "剩 ${diff.inHours} 小时 ${diff.inMinutes % 60} 分钟";
    return "剩 ${diff.inMinutes} 分钟";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('外链管理中心'),
        actions:[
          IconButton(
            icon: Icon(Icons.cleaning_services),
            tooltip: '清理过期链接',
            onPressed: _clearExpiredLinks,
          )
        ],
      ),
      body: Consumer<S3StorageService>(
        builder: (context, s3, child) {
          if (s3.shareHistory.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children:[
                  Icon(Icons.link_off, size: 64, color: Colors.grey.withOpacity(0.5)),
                  SizedBox(height: 16),
                  Text("暂无分享链接", style: TextStyle(color: Colors.grey)),
                  Text("在文件列表中点击分享按钮即可生成", style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              )
            );
          }
          return ListView.builder(
            itemCount: s3.shareHistory.length,
            itemBuilder: (context, index) {
              final item = s3.shareHistory[index];
              final expireDate = DateTime.fromMillisecondsSinceEpoch(item['expireAt']);
              final timeStr = DateFormat('yyyy-MM-dd HH:mm').format(expireDate);
              final isExpired = DateTime.now().millisecondsSinceEpoch > item['expireAt'];

              return Card(
                elevation: isExpired ? 0 : 2,
                color: isExpired ? Theme.of(context).cardColor.withOpacity(0.5) : null,
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isExpired ? Colors.grey.withOpacity(0.2) : Colors.purple.withOpacity(0.1),
                    child: Icon(Icons.link, color: isExpired ? Colors.grey : Colors.purple),
                  ),
                  title: Text(
                    item['fileName'], 
                    maxLines: 1, 
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(decoration: isExpired ? TextDecoration.lineThrough : null),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children:[
                        Text('到期: $timeStr', style: TextStyle(fontSize: 12)),
                        Text(
                          _getRemainingTime(item['expireAt']),
                          style: TextStyle(color: isExpired ? Colors.red : Colors.green, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children:[
                      if (!isExpired)
                        IconButton(
                          icon: Icon(Icons.copy, color: Colors.blue),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: item['url']));
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制外链')));
                          },
                        ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => s3.deleteShareRecord(index),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}


