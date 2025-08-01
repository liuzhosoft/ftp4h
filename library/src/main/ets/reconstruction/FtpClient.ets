import { FileInfo } from "../FileInfo";
import { AccessOptions } from "./AccessOptions";
import { FtpContext } from "./FtpContext";
import { positiveCompletion, positiveIntermediate } from "../parseControlResponse";
import FtpLogger from "./FtpLogger";
import { FtpTransfer } from "./transfer/FtpTransfer";
import { CharsetUtil } from "../StringEncoding";
import { parseList } from "../parseList";
import { FtpTransferController } from "./FtpTransferController";

const tag = "FtpClient";

export class FtpClient {
  readonly context: FtpContext;
  private listCommands: string[] = [];
  private curPath: string = "";

  constructor(timeout: number) {
    this.context = new FtpContext(timeout);
  }

  isConnected(): Promise<boolean> {
    return this.context.isConnected();
  }

  async access(options: AccessOptions): Promise<boolean> {
    const resp = await this.context.access(options);
    return positiveCompletion(resp.code);
  }

  async list(path: string): Promise<FileInfo[]> {
    path = await this.toAbsolutePath(path);
    if (this.listCommands.length == 0) {
      const listHiddenFile = this.context.accessOptions.listHiddenFile == true;
      const listCommands = listHiddenFile ? ["LIST -a", "LIST"] : ["LIST"];
      if (this.context.hasFeature("MLST")) {
        listCommands.splice(0, 0, "MLSD");
      }
      this.listCommands.push(...listCommands);
    }
    FtpLogger.debug(tag,
      `${this.context.instanceFlag()} list ${path} with commands ${JSON.stringify(this.listCommands)}`);
    for (const cmd of this.listCommands) {
      const command = path == "" ? cmd : `${cmd} ${path}`;
      let transfer: FtpTransfer | undefined;
      try {
        transfer = await this.context.prepareTransfer();
        if (!transfer) {
          continue;
        }
        let receivedLen = 0;
        const receivedData: ArrayBuffer[] = [];
        const resp = await transfer.input(command, -1, (data) => {
          // FtpLogger.debug(tag, "\n" + CharsetUtil.decode(data, this.context.encoding()));
          receivedData.push(data);
          receivedLen += data.byteLength;
        });
        FtpLogger.debug(tag, `received len = ${receivedLen}`);
        const combinedData = new Uint8Array(receivedLen);
        let offset = 0;
        receivedData.forEach(data => {
          combinedData.set(new Uint8Array(data), offset);
          offset += data.byteLength;
        });
        const listDataStr = CharsetUtil.decode(combinedData.buffer, this.context.encoding());
        return parseList(listDataStr);
        // FtpLogger.debug(tag, `list ${path} with cmd ${command} resp is ${resp.message}`);
      } catch (e) {
        FtpLogger.error(tag, `list with ${cmd} failed ${JSON.stringify(e)}`);
      } finally {
        await transfer?.close();
      }
    }
    throw new Error(`list ${path} failed`);
  }

  async rename(srcPath: string, dstPath: string): Promise<boolean> {
    srcPath = await this.toAbsolutePath(srcPath);
    dstPath = await this.toAbsolutePath(dstPath);
    const rnfrResp = await this.context.send(`RNFR ${srcPath}`);
    if (!positiveIntermediate(rnfrResp.code)) {
      return false;
    }
    const rntoResp = await this.context.send(`RNTO ${dstPath}`);
    return positiveCompletion(rntoResp.code);
  }

  async remove(path: string): Promise<boolean> {
    const resp = await this.context.send(`DELE ${await this.toAbsolutePath(path)}`);
    return positiveCompletion(resp.code);
  }

  async removeDir(path: string): Promise<boolean> {
    path = await this.toAbsolutePath(path);
    if (path == "/") {
      return false;
    }
    let success = true;
    for (const file of await this.list(path)) {
      if (file.isDirectory) {
        success = success && (await this.removeDir(path + "/" + file.name));
      } else {
        success = success && (await this.remove(path + "/" + file.name));
      }
    }
    return success && positiveCompletion((await this.context.send(`RMD ${path}`)).code);
    // return this.rememberCurDir(async () => {
    //   if (!(await this.cd(path)) || !(await this.clearWorkingDir()) || !(await this.cdup())) {
    //     return false;
    //   }
    //   let remoteDirName = "";
    //   if (path.indexOf("/") != -1) {
    //     let lastIndex = path.lastIndexOf("/");
    //     remoteDirName = path.substring(lastIndex + 1, path.length);
    //   } else if (path.indexOf("\\") != -1) {
    //     let lastIndex = path.lastIndexOf("\\");
    //     remoteDirName = path.substring(lastIndex + 1, path.length);
    //   } else if (path.indexOf("\\\\") != -1) {
    //     let lastIndex = path.lastIndexOf("\\\\");
    //     remoteDirName = path.substring(lastIndex + 1, path.length);
    //   } else {
    //     remoteDirName = path;
    //   }
    //   return await this.removeEmptyDir(remoteDirName);
    // });
  }

  async cd(path: string): Promise<boolean> {
    path = await this.toAbsolutePath(path);
    const resp = await this.context.send(`CWD ${path}`);
    if (positiveCompletion(resp.code)) {
      this.curPath = path;
      return true;
    }
    return false;
  }

  async cdup(): Promise<boolean> {
    if (positiveCompletion((await this.context.send("CDUP")).code)) {
      this.curPath = await this.pwd();
      return true;
    }
    return false;
  }

  async pwd(): Promise<string> {
    const resp = await this.context.send("PWD");
    const parsed = resp.message.match(/"(.+)"/);
    if (parsed === null || parsed[1] === undefined) {
      throw new Error(`Can't parse response to command 'PWD': ${resp.message}`);
    }
    this.curPath = parsed[1];
    return parsed[1];
  }

  async size(path: string): Promise<number> {
    path = await this.toAbsolutePath(path);
    const resp = await this.context.send(`SIZE ${path}`);
    const size = parseInt(resp.message.slice(4), 10);
    if (Number.isNaN(size)) {
      throw new Error(`get size for ${path} failed! ${resp.message}`);
    }
    return size;
  }

  async read(
    path: string,
    onReceiveData: (data: ArrayBuffer) => void,
    onReady?: (controller: FtpTransferController) => void,
    offset?: number,
    targetLen?: number,
  ): Promise<void> {
    path = await this.toAbsolutePath(path);
    let transfer: FtpTransfer | undefined;
    try {
      transfer = await this.context.prepareTransfer();
      const controller: FtpTransferController = {
        cancel: async () => {
          await transfer?.close();
        }
      };
      onReady?.(controller);
      if (offset != undefined && offset > 0) {
        const restResp = await this.context.send(`REST ${offset}`);
        if (!positiveIntermediate(restResp.code)) {
          throw new Error(`seek to ${offset} failed`);
        }
      }
      targetLen = targetLen ? targetLen : (await this.size(path));
      const resp = await transfer?.input(`RETR ${path}`, targetLen, (data) => onReceiveData(data));
      if (!positiveCompletion(resp.code)) {
        throw new Error("download failed " + resp.message);
      }
    } finally {
      await transfer?.close();
    }
  }

  async write(
    path: string,
    source: () => Promise<ArrayBuffer>,
    onReady?: (controller: FtpTransferController) => void,
    onSend?: (currentSendLen: number, totalSendLen: number) => void
  ): Promise<void> {
    path = await this.toAbsolutePath(path);
    let transfer: FtpTransfer | undefined;
    try {
      transfer = await this.context.prepareTransfer();
      const controller: FtpTransferController = {
        cancel: async () => {
          await transfer?.close();
        }
      };
      onReady?.(controller);
      const resp = await transfer?.output(`STOR ${path}`, () => source(), (cur, total) => onSend?.(cur, total));
      if (!positiveCompletion(resp.code)) {
        throw new Error("download failed " + resp.message);
      }
    } finally {
      await transfer?.close();
    }
  }

  private async clearWorkingDir(): Promise<boolean> {
    let hasError = false;
    for (const file of await this.list(this.curPath)) {
      if (file.isDirectory) {
        if (!(await this.cd(file.name)) || !(await this.clearWorkingDir()) || !(await this.cdup())
          || !(await this.removeEmptyDir(file.name))) {
          hasError = true;
        }
      } else {
        hasError = !(await this.remove(file.name));
      }
    }
    return !hasError;
  }

  private async removeEmptyDir(path: string) {
    return positiveCompletion((await this.context.send(`RMD ${await this.toAbsolutePath(path)}`)).code);
  }

  private async rememberCurDir<T>(block: () => Promise<T>) {
    const curDir = this.curPath.length > 0 ? this.curPath : (await this.pwd());
    try {
      return await block();
    } finally {
      if (await this.isConnected()) {
        await this.cd(curDir);
      }
    }
  }

  private async toAbsolutePath(path: string): Promise<string> {
    if (path.startsWith("/")) {
      return path;
    }
    if (this.curPath.length == 0) {
      this.curPath = await this.pwd();
    }
    return `${this.curPath.endsWith("/") ? this.curPath : `${this.curPath}/`}${path}`;
  }
}
