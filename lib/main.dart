import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/s3_storage_service.dart';


void main() {
  runApp(
    // 替换原来的 ChangeNotifierProvider 为 MultiProvider
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => S3StorageService()),
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
            
            // [新增]：VFS 虚拟目录机制说明
              ListTile(
                leading: Icon(Icons.cloud_sync, color: Colors.blue),
                title: Text('OSCA VFS 虚拟文件系统增强', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  '针对 S3 对象存储扁平化命名空间（Flat Namespace）及缺乏原生目录实体的特性，\n'
                  '本架构引入云端元数据索引 (.osca_vfs.json) 以构建虚拟目录树。\n'
                  '• 支持空目录持久化：解决原生协议中空文件夹无法独立存在的限制。\n'
                  '• 高效目录管理：通过更新元数据实现毫秒级目录创建与重组，避免大文件物理移动的高昂开销。\n'
                  '• 交互一致性：提供符合本地文件系统直觉的层级视图，优化文件组织与管理效率。',
                  style: TextStyle(fontSize: 12, height: 1.4),
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
                Text('⚠️ S3特性：修改路径或名称将触发复制并删除原文件', style: TextStyle(fontSize: 12, color: Colors.orange)),
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

  // [配套修改]: 下载方法不再需要 finally 去兜底关闭
  Future<void> _handleDownload(Map<String, dynamic> item) async {
    if (item['isDir']) {
      _showMsg("暂不支持直接下载整个文件夹", isError: true);
      return;
    }

    String localDir = "";
    if (Platform.isAndroid) {
      Directory? dir = await getExternalStorageDirectory();
      localDir = dir?.path ?? (await getApplicationDocumentsDirectory()).path;
    } else if (Platform.isIOS) {
      Directory dir = await getApplicationDocumentsDirectory();
      localDir = dir.path;
    } else {
      String? selected = await FilePicker.platform.getDirectoryPath();
      if (selected == null) return;
      localDir = selected;
    }

    String localPath = p.join(localDir, item['name']);
    final task = TransferTask();
    
    // 调用新的弹窗逻辑
    _showProgressDialog("正在下载...", item['name'], task, (onProgressReady) async {
      try {
        await context.read<S3StorageService>().downloadFile(item['key'], localPath, task, onProgressReady);
        if (!task.isCancelled) _showMsg("下载成功: $localPath");
      } catch (e) {
        if (!task.isCancelled) _showMsg("下载失败: $e", isError: true);
      }
    });
  }

  // [配套修改]: 上传方法同理
  Future<void> _handleUpload() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;

    String localPath = result.files.single.path!;
    String fileName = result.files.single.name;
    String remoteKey = "$_currentPrefix$fileName";

    final task = TransferTask();

    _showProgressDialog("正在上传...", fileName, task, (onProgressReady) async {
      try {
        await context.read<S3StorageService>().uploadFile(localPath, remoteKey, task, onProgressReady);
        if (!task.isCancelled) {
          _showMsg("上传成功");
          _loadFiles();
        }
      } catch (e) {
        if (!task.isCancelled) _showMsg("上传失败: $e", isError: true);
      }
    });
  }

  // [核心修复]: 重新设计的长任务进度弹窗
  void _showProgressDialog(String title, String fileName, TransferTask task, Future<void> Function(Function(double, String)) runTask) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        double currentProgress = 0;
        String currentSpeed = "初始化连接...";
        bool taskStarted = false;

        return StatefulBuilder(
          builder: (innerContext, setDialogState) {
            
            // 更新进度条方法
            void updateProgress(double p, String speed) {
              // 修复点 1：检查的是弹窗内部的 context，而不是外层页面的 context
              if (!innerContext.mounted) return; 
              setDialogState(() { 
                currentProgress = p; 
                currentSpeed = speed; 
              });
              // 移除了这里原有的 p >= 1.0 就自动 pop 的危险逻辑
            }
            
            // 只在弹窗第一次构建时启动任务
            if (!taskStarted) {
              taskStarted = true;
              // 修复点 2：监听整个异步任务，无论成功、失败还是取消，都在彻底执行完毕后自动关闭弹窗
              runTask(updateProgress).whenComplete(() {
                if (innerContext.mounted && Navigator.canPop(dialogContext)) {
                  Navigator.pop(dialogContext);
                }
              });
            }

            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children:[
                  LinearProgressIndicator(value: currentProgress),
                  SizedBox(height: 10),
                  Text("${(currentProgress * 100).toStringAsFixed(1)}%   -   $currentSpeed", style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 5),
                  Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey)),
                ],
              ),
              actions:[
                TextButton(
                  onPressed: () {
                    task.cancel(); // 触发中止令牌
                    // 点击取消后不需要手动 pop，因为 task 抛出异常会触发上方的 whenComplete 自动关闭
                  },
                  child: Text('取消任务', style: TextStyle(color: Colors.red)),
                )
              ],
            );
          },
        );
      },
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // [修改]: 支持搜索框切换
        title: _isSearching 
          ? TextField(
              autofocus: true,
              style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
              decoration: InputDecoration(hintText: '搜索当前目录文件...', border: InputBorder.none),
              onChanged: (val) => setState(() => _searchQuery = val),
            )
          : Text('OSCA - ${_currentPrefix.isEmpty ? '根目录' : _currentPrefix}', style: TextStyle(fontSize: 16)),
        actions: [
          // [新增]: 搜索切换按钮
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchQuery = ''; // 关闭时清空搜索
              });
            },
          ),
          // [新增]: 创建文件夹按钮
          IconButton(icon: Icon(Icons.create_new_folder), onPressed: _handleCreateFolder),
          IconButton(icon: Icon(Icons.upload), onPressed: _isLoading ? null : _handleUpload),
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => ConfigPage())),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _filteredFiles.length, // [修改]: 使用过滤后的数组
              itemBuilder: (context, index) {
                final item = _filteredFiles[index]; // [修改]: 取出过滤后的 Item
                
                // 1. 基础卡片 Widget
                Widget card = Card(
                  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      item['isDir'] ? Icons.folder : Icons.insert_drive_file,
                      color: item['isDir'] ? Colors.orange : Colors.blue,
                    ),
                    title: Text(item['name']),
                    // 使用格式化后的大小
                    subtitle: item['isDir'] ? null : Text(_formatFileSize(item['size'])),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children:[
                        // ... 保留前面的 属性、下载、删除 按钮 ...
                        IconButton(
                          icon: Icon(Icons.info_outline, color: Colors.green),
                          tooltip: '属性与编辑',
                          onPressed: () => _showPropertiesDialog(item),
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
                      if (item['isDir']) {
                        setState(() {
                          _currentPrefix = item['key'];
                          _isSearching = false; // 进入新目录时重置搜索
                          _searchQuery = '';
                        });
                        _loadFiles();
                      }
                    },
                  ),
                );

                // 2. 文件夹作为接收目标 (DragTarget)
                if (item['isDir']) {
                  return DragTarget<Map<String, dynamic>>(
                    onWillAccept: (data) => data != null && !data['isDir'], // 仅允许文件拖入
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
                        // 拖入时高亮显示
                        decoration: BoxDecoration(
                          border: candidateData.isNotEmpty ? Border.all(color: Colors.blue, width: 2) : null,
                        ),
                        child: card,
                      );
                    },
                  );
                } 
                // 3. 文件作为可拖拽源 (LongPressDraggable)
                else {
                  return LongPressDraggable<Map<String, dynamic>>(
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
