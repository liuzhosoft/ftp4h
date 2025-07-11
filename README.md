## ftp4h

## 简介

ftp4h (ftp for harmony) 是适用于Harmony的ftp客户端.

本项目已用于产品《流舟文件》经大量用户验证，欢迎反馈问题以及提交PR。

## 下载安装

```shell
ohpm install @liuzhosoft/ftp4h
```

## 使用说明

注意：全局搜索项目中的‘xxx’，需要替换修改为真实的邮箱，账号密码,服务器地址。
如需测试ftps加密传输，需要提前准备好自签名证书放置于src/main/resources/rawfile文件夹下，同时替换SamplePage.ets文件的loginServer方法的证书名称。

## 注意事项

- **download接口建议放在IO线程**

  在网速非常快的环境中下载大文件，会造成UI线程的阻塞以及内存溢出

## 接口说明

| 接口名             | 参数                            | 返回值                 | 说明                            |
|-----------------|-------------------------------|---------------------|-------------------------------|
| access          | AccessOptions                 | FTPResponse         | 登录FTP服务器                      |
| list            | string                        | FileInfo            | 获取文件列表                        |
| size            | string                        | number              | 获取文件大小                        |
| uploadFrom      | FtpReadStream/string, string  | FTPResponse         | 上传文件                          |
| downloadTo      | FtpWriteStream/string, string | FTPResponse         | 下载文件                          |
| features        | 无                             | Map<string, string> | 获取服务器能力                       |
| cd              | string                        | FTPResponse         | 设置工作目录                        |
| cdup            | 无                             | FTPResponse         | 从当前工作目录切换到父目录                 |
| remove          | string                        | FTPResponse         | 删除文件                          |
| lastMod         | string                        | Date                | 获取最后修改的时间                     |
| pwd             | 无                             | string              | 获取当前目录                        |
| ensureDir       | string                        | void                | 确认远程是否存在目录，不存在则会自动创建          |
| removeEmptyDir  | string                        | FTPResponse         | 删除选择的文件夹，文件夹不为空则会失败报错         |
| removeDir       | string                        | void                | 删除选择的文件夹中所有子文件夹和文件，同时删除选择的文件夹 |
| clearWorkingDir | 无                             | void                | 清空当前文件夹中所有子文件夹和文件，但是保留当前的文件夹  |
| rename          | string, string                | FTPResponse         | 重命名文件                         |
| uploadFromDir   | string, string                | void                | 上传目录                          |
| downloadToDir   | string, string                | void                | 下载目录                          |
| close           | 无                             | void                | 关闭连接，释放资源                     |

## 约束与限制

在下述版本验证通过：

本库当前支持ftp被动模式，不支持主动模式；支持FTP,隐式tls加密的FTPS。

本库支持MLSD、Unix、DOS格式的目录列表解析。

本库支持@ohos.file.fs模块支持的文件类型。

本库支持Binary模式传输数据。

## 贡献代码

我们期望得到更多的问题反馈，以及积极的PR

## 开源协议

本项目基于 [MIT License](./LICENSE)

上游项目来自 [BasicFtp](https://gitee.com/openharmony-tpc/openharmony_tpc_samples/tree/master/BasicFtp)
，开源协议为 [MIT License](https://gitee.com/openharmony-tpc/openharmony_tpc_samples/blob/master/BasicFtp/LICENSE)

## TODO

- 在支持MLST的服务器上使用MLST来获取单个文件(文件夹)信息