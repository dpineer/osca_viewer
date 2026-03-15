# OSCA Viewer

OSCA Viewer 是一个用于访问和管理 S3 兼容存储服务的桌面客户端应用程序。

## 功能特性

- **文件浏览**：查看远程存储桶中的文件和目录
- **文件上传**：将本地文件上传到远程存储（支持大文件分片上传）
- **文件下载**：将远程文件下载到本地（支持取消和进度显示）
- **文件删除**：删除远程文件或目录（支持递归删除）
- **文件重命名/移动**：支持文件的重命名和移动操作
- **创建文件夹**：支持创建虚拟文件夹
- **认证配置**：配置访问 S3 兼容服务所需的认证信息
- **主题切换**：支持浅色和深色主题
- **文件搜索**：支持在当前目录中搜索文件
- **拖拽操作**：支持拖拽文件到文件夹中进行移动
- **进度显示**：显示上传/下载进度和传输速度
- **任务取消**：支持取消正在进行的上传/下载任务
- **UI生命周期管理**：修复了异步并发与UI生命周期不同步的bug，确保在大文件上传/下载完成前不会出现UI崩溃

## OSCA VFS 虚拟文件系统增强

针对 S3 对象存储扁平化命名空间（Flat Namespace）及缺乏原生目录实体的特性，本架构引入云端元数据索引 (.osca_vfs.json) 以构建虚拟目录树。

- **支持空目录持久化**：解决原生协议中空文件夹无法独立存在的限制
- **高效目录管理**：通过更新元数据实现毫秒级目录创建与重组，避免大文件物理移动的高昂开销
- **交互一致性**：提供符合本地文件系统直觉的层级视图，优化文件组织与管理效率

## 依赖要求

- Flutter SDK (3.10.8+)
- Dart SDK (3.10.8+)

## 安装和使用

1. 确保已安装 Flutter SDK
2. 运行 `flutter pub get` 安装依赖
3. 运行 `flutter run` 启动应用程序

## 编译安卓Release版本

要编译安卓Release版本，请执行以下命令：

```bash
flutter build apk --release
```

编译完成后，Release版本的APK文件将生成在 `build/app/outputs/flutter-apk/app-release.apk`，文件大小约为49.4MB。

如需生成分架构的APK（更小的文件大小），可以使用：
```bash
flutter build apk --split-per-abi --release
```

这将生成针对不同CPU架构的APK文件，如armeabi-v7a、arm64-v8a和x86_64。

## 编译Linux Release版本

要编译Linux Release版本，请执行以下命令：

```bash
flutter build linux --release
```

编译完成后，Release版本的可执行文件将生成在 `build/linux/x64/release/bundle/osca_viewer`，文件大小约为23.3KB。

要运行该应用程序，请进入bundle目录并执行：
```bash
cd build/linux/x64/release/bundle
./osca_viewer
```

注意：运行Linux桌面应用程序需要系统安装相应的图形库依赖。

## 配置

首次使用时，需要在"配置 S3 连接"页面输入以下信息：

- AccessKey (AK)
- SecretKey (SK)
- Bucket 名称
- Endpoint (网关地址)

## 使用说明

1. 在"配置 S3 连接"页面完成认证配置
2. 切换到"文件管理"页面浏览远程文件
3. 使用上传按钮将文件上传到当前目录
4. 使用下载和删除按钮管理远程文件
5. 使用搜索功能在当前目录中查找文件
6. 使用拖拽功能将文件移动到文件夹中
7. 使用属性按钮查看和编辑文件属性

## 技术实现

- **S3 签名算法**：实现了 AWS S3 V4 签名算法，确保与 S3 兼容服务的安全通信
- **大文件上传**：支持大于 5MB 的文件分片上传，提高大文件传输效率
- **中文支持**：正确处理包含中文字符的文件名和路径
- **进度监控**：实时显示上传/下载进度和传输速度
- **错误处理**：完善的错误处理和用户提示机制

## 项目结构

- `lib/main.dart`：应用程序主入口和主要页面
- `lib/services/s3_storage_service.dart`：S3 存储服务封装
- `lib/services/s3_signer.dart`：S3 签名算法实现

## 依赖库

- flutter: Flutter 框架
- shared_preferences: 本地配置存储
- file_picker: 文件选择器
- provider: 状态管理
- http: HTTP 请求
- crypto: 加密算法（用于 S3 签名）
- intl: 国际化支持

## 许可证

[CC-BY-NC-SA]