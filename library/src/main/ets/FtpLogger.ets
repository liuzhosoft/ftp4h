type LogFunc = (tag: string, message: string, error?: object) => void;

class FtpLogger {
  debug: LogFunc =
    (tag, msg, err) => err ? console.debug(`[ftp4h]${tag}`, msg, err) : console.debug(`[ftp4h]${tag}`, msg);
  info: LogFunc =
    (tag, msg, err) => err ? console.log(`[ftp4h]${tag}`, msg, err) : console.log(`[ftp4h]${tag}`, msg);
  error: LogFunc =
    (tag, msg, err) => err ? console.error(`[ftp4h]${tag}`, msg, err) : console.error(`[ftp4h]${tag}`, msg);
}

export default new FtpLogger();