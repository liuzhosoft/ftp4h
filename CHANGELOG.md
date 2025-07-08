## 1.0.0

相较于原项目版本[@ohos/basic-ftp(V1.0.2)](https://ohpm.openharmony.cn/#/cn/detail/@ohos%2Fbasic-ftp/v/1.0.2)
更新如下内容：

- 支持 GBK编码
- 支持 文件区间下载
- 修复 transfer中数据缓存改为多实例，避免多个client情况下导致数据混乱
- 修复 下载文件时将文件bytes转string再转bytes的错误行为，避免下载过程造成文件内容错乱



