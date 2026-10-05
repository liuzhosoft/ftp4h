import { FileInfo, FileType } from "./models/FileInfo";
import { AccessOptions } from "./AccessOptions";
import { FtpContextImpl } from "./FtpContextImpl";
import { positiveCompletion, positiveIntermediate } from "./parser/parseControlResponse";
import FtpLogger from "./FtpLogger";
import { FtpTransfer } from "./transfer/FtpTransfer";
import { CharsetUtil } from "./util/StringEncoding";
import { parseList } from "./parser/parseList";
import { FtpTransferController } from "./FtpTransferController";
import { FtpContext } from "./FtpContext";
import { FtpError } from "./FtpErrors";
import { parseLine, parseMLSxDate } from "./parser/parseListMLSD";

const tag = "FtpClient";

export class FtpClient {
  readonly context: FtpContext;
  private listCommands: string[] = [];
  private curPath: string = "";

  constructor(timeout: number = 30000) {
    this.context = new FtpContextImpl(timeout);
  }

  isConnected(): Promise<boolean> {
    return this.context.isConnected();
  }

  async access(options: AccessOptions): Promise<boolean> {
    const resp = await this.context.access(options);
    return positiveCompletion(resp.code);
  }

  async list(path: string, includeHiddenFile: boolean = false): Promise<FileInfo[]> {
    path = await this.toAbsolutePath(path);
    if (this.listCommands.length == 0) {
      const listCommands = includeHiddenFile ? ["LIST -a", "LIST"] : ["LIST"];
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
        FtpLogger.error(tag, `list with ${cmd} failed ${JSON.stringify(e as Error)}`);
      } finally {
        await transfer?.close();
      }
    }
    throw new FtpError(`list ${path} failed`);
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
      throw new FtpError(`Can't parse response to command 'PWD': ${resp.message}`);
    }
    this.curPath = parsed[1];
    return parsed[1];
  }

  async size(path: string): Promise<number> {
    path = await this.toAbsolutePath(path);
    const resp = await this.context.send(`SIZE ${path}`);
    const size = parseInt(resp.message.slice(4), 10);
    if (resp.code !== 213 || Number.isNaN(size) || size < 0) {
      throw new FtpError(`get size for ${path} failed! ${resp.message}`);
    }
    return size;
  }

  /** 查询指定文件的大小和修改时间。优先使用控制通道，避免为单个文件重新列出整个目录。 */
  async stat(path: string): Promise<FileInfo | undefined> {
    path = await this.toAbsolutePath(path);
    const end = path.endsWith("/") && path !== "/" ? path.length - 1 : path.length;
    const normalized = path.substring(0, end);
    const split = normalized.lastIndexOf("/");
    const name = normalized.substring(split + 1);
    if (this.context.hasFeature("MLST")) {
      const response = await this.context.send(`MLST ${path}`);
      if (response.code === 250) {
        for (const line of response.message.split(/\r?\n/)) {
          // MLST 的正文行以空格开头，名称可能是完整路径；cdir/pdir 在单文件查询中也是目录。
          const facts = line.trimStart().replace(/(^|;)type=[cp]dir;/i, "$1type=dir;");
          if (/^\S+=\S*;/.test(facts)) {
            const info = parseLine(facts);
            if (info !== undefined) {
              info.name = name;
              return info;
            }
          }
        }
        throw new FtpError(`Invalid MLST response: ${response.message}`);
      }
      if (response.code !== 500 && response.code !== 502 && response.code !== 504 && response.code !== 550) {
        throw new FtpError(`MLST failed: ${response.message}`);
      }
      // 550 同时可能表示不存在或没有访问权限，继续查询确认，不能直接当成文件已删除。
    }
    const size = await this.context.send(`SIZE ${path}`);
    if (size.code === 213) {
      const info = new FileInfo(name);
      info.type = FileType.File;
      info.size = Number(size.message.substring(4).trim());
      if (!Number.isSafeInteger(info.size) || info.size < 0) {
        throw new FtpError(`Invalid SIZE response: ${size.message}`);
      }
      const modified = await this.context.send(`MDTM ${path}`);
      if (modified.code === 213 && /^\d{14}(\.\d+)?$/.test(modified.message.substring(4).trim())) {
        info.rawModifiedAt = modified.message.substring(4).trim();
        info.modifiedAt = parseMLSxDate(info.rawModifiedAt);
      } else if (modified.code !== 500 && modified.code !== 502 && modified.code !== 504) {
        throw new FtpError(`MDTM failed: ${modified.message}`);
      }
      return info;
    }
    if (size.code !== 500 && size.code !== 502 && size.code !== 504 && size.code !== 550) {
      throw new FtpError(`SIZE failed: ${size.message}`);
    }
    // 旧服务端可能不支持单文件命令，SIZE 也不能查询目录。仅这些情况退回目录查询，保留错误。
    const entries = await this.list(normalized.substring(0, split) || "/", true);
    return entries.find(entry => entry.name === name);
  }

  async mkdirs(path: string): Promise<boolean> {
    path = await this.toAbsolutePath(path);
    if (!(await this.cd(path))) {
      const paths = path.split("/");
      if (!(await this.cd("/"))) {
        return false;
      }
      for (const subPath of paths) {
        if (subPath && !(await this.cd(subPath))) {
          const mkdResp = await this.context.send(`MKD ${subPath}`);
          if (!positiveCompletion(mkdResp.code)) {
            return false;
          }
        }
      }
    }
    return true;
  }

  async read(
    path: string,
    onReceiveData: (data: ArrayBuffer) => void,
    onReady?: (controller: FtpTransferController) => void,
    offset?: number,
    targetLen?: number
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
      if (offset !== undefined && offset > 0) {
        const restResp = await this.context.send(`REST ${offset}`);
        if (!positiveIntermediate(restResp.code)) {
          throw new FtpError(`seek to ${offset} failed`);
        }
      }
      // 未指定长度时读取偏移之后的正文；显式传入的 0 代表空内容，不能回退为整文件大小。
      targetLen = targetLen ?? Math.max(0, (await this.size(path)) - (offset ?? 0));
      const resp = await transfer?.input(`RETR ${path}`, targetLen, (data) => onReceiveData(data));
      if (!positiveCompletion(resp.code)) {
        throw new FtpError("download failed " + resp.message);
      }
    } finally {
      await transfer?.close();
    }
  }

  async write(
    path: string,
    source: (buf: ArrayBuffer) => Promise<number>,
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
      const resp = await transfer?.output(`STOR ${path}`, (buf) => source(buf), (cur, total) => onSend?.(cur, total));
      if (!positiveCompletion(resp.code)) {
        throw new FtpError("download failed " + resp.message);
      }
    } finally {
      await transfer?.close();
    }
  }

  async close() {
    await this.context?.close();
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
