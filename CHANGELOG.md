### 2.0.0

- 全面重构项目

## 1.0.1

### 优化

- 数据传输时连接dataSocket的操作由发起command时进行
- 修改FtpClient构造时context的入参为cacheDir
- 调整FTP的读写接口，通过抽象Stream更好的支持多样读/写源

### 修复

- 下载文件时指定fileSize无法中断下载的问题
- 在支持GBK的服务器上无法正常通信的问题，向服务器上行数据时处理GBK编码
- 解决循环依赖的问题
- 传入的cacheDir目录不存在时，无法正常list服务目录的问题

## 1.0.0

相较于原项目版本[@ohos/basic-ftp(V1.0.2)](https://ohpm.openharmony.cn/#/cn/detail/@ohos%2Fbasic-ftp/v/1.0.2)
更新如下内容：

- 支持 GBK编码
- 支持 文件区间下载
- 修复 transfer中数据缓存改为多实例，避免多个client情况下导致数据混乱
- 修复 下载文件时将文件bytes转string再转bytes的错误行为，避免下载过程造成文件内容错乱



