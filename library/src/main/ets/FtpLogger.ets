type LogFunc = (tag: string, message: string, error?: object) => void;

class FtpLogger {
  debug: LogFunc = (tag, msg, err) => err ? console.debug(tag, msg, err) : console.debug(tag, msg);
  info: LogFunc = (tag, msg, err) => err ? console.log(tag, msg, err) : console.log(tag, msg);
  error: LogFunc = (tag, msg, err) => err ? console.error(tag, msg, err) : console.error(tag, msg);
}

export default new FtpLogger();