## ftp4h

## 简介

ftp4h (ftp for harmony) 是适用于Harmony的ftp客户端.

本项目已用于产品《流舟文件》经大量用户验证，欢迎反馈问题以及提交PR。

**ftp4h的2.0版本经过重构，存在API变动及结构调整。**

## 下载安装

```shell
ohpm install @liuzhosoft/ftp4h
```

## 使用说明

- 登录到目标服务器

```extendtypescript
const ftpClient = new FtpClient();
ftpClient.access({
  host: "192.168.1.1",
  port: 21,
  user: "ftpuser",
  password: "ftppwd",
  encoding: "utf-8"
});
```

- 获取文件列表

```extendtypescript
ftpClient.list("/");
```

- 读取/下载文件

```extendtypescript
// read by stream
ftpClient.read(
  remoteFilePath,
  // onReceiveData = outputStream
  (data: ArrayBuffer) => {
    // streaming
  },
  // onReady
  (controller: FtpTransferController) => {
    // you can cancel the transfer using controller.cancel()
  },
  0, // read file offset
  fileLen, // read length
);
```

- 上传文件

```extendtypescript
// upload by stream
ftpClient.write(
  remoteFilePath,
  // source = inputStream
  async () => {
    // provide the source by stream
    return ArrayBuffer;
  },
  // onReady
  (controller: FtpTransferController) => {
    // you can cancel the transfer using controller.cancel()
  },
  // onSend, progress callback
  (currentSendLen: number, totalSendLen: number) => {
    // sent $totalSendLen bytes
  }
);
```

- 重命名/移动

```extendtypescript
ftpClient.rename(fromPath, toPath);
```

- 删除

```extendtypescript
client.remove(path);
client.removeDir(path);
```

## 约束与限制

## 贡献代码

我们期望得到更多的问题反馈，以及积极的PR

## 开源协议

本项目基于 [MIT License](./LICENSE)

上游项目来自 [BasicFtp](https://gitee.com/openharmony-tpc/openharmony_tpc_samples/tree/master/BasicFtp)
，开源协议为 [MIT License](https://gitee.com/openharmony-tpc/openharmony_tpc_samples/blob/master/BasicFtp/LICENSE)

## TODO

