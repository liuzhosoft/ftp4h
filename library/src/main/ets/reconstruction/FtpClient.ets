import { FileInfo } from "../FileInfo";
import { AccessOptions } from "./AccessOptions";
import { FtpContext } from "./FtpContext";
import { positiveCompletion } from "../parseControlResponse";
import FtpLogger from "./FtpLogger";
import { FtpTransfer } from "./transfer/FtpTransfer";
import { CharsetUtil } from "../StringEncoding";
import { parseList } from "../parseList";

const tag = "FtpClient";

export class FtpClient {
  readonly context: FtpContext;
  private currentPath: string = "";
  private listCommands: string[] = [];

  constructor(timeout: number) {
    this.context = new FtpContext(timeout);
  }

  async access(options: AccessOptions): Promise<boolean> {
    const resp = await this.context.access(options);
    return positiveCompletion(resp.code);
  }

  async list(path: string = "/"): Promise<FileInfo[]> {
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
        const resp = await transfer.input(command, (data) => {
          // FtpLogger.debug(tag, CharsetUtil.decode(data, this.context.encoding()));
          receivedData.push(data);
          receivedLen += data.byteLength;
        });
        const combinedData = new Uint8Array(receivedLen);
        let offset = 0;
        receivedData.forEach(data => {
          combinedData.set(new Uint8Array(data), offset);
          offset += data.byteLength;
        });
        const listDataStr = CharsetUtil.decode(combinedData.buffer, this.context.encoding());
        return parseList(listDataStr);
        FtpLogger.debug(tag, `list ${path} with cmd ${command} resp is ${resp.message}`);
      } catch (e) {
        FtpLogger.error(tag, `list with ${cmd} failed`, e);
      } finally {
        await transfer?.close();
      }
    }
    throw new Error(`list ${path} failed`);
  }

  async pwd(): Promise<string> {
    const resp = await this.context.send("PWD");
    const parsed = resp.message.match(/"(.+)"/);
    if (parsed === null || parsed[1] === undefined) {
      throw new Error(`Can't parse response to command 'PWD': ${resp.message}`);
    }
    this.currentPath = parsed[1];
    return parsed[1];
  }
}
