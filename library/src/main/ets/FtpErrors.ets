export class FtpError implements Error {
  name: string = "FtpError";
  message: string;
  stack?: string | undefined;
  cause?: Error;

  constructor(message: string, stack?: string | undefined, cause?: Error) {
    this.message = message;
    this.stack = stack;
    this.cause = cause;
  }
}

export class FtpLoginFailedError extends FtpError {
  name: string = "LoginFailedError";

  constructor(message: string, stack?: string, error?: Error) {
    super(message, stack, error);
  }
}

export class FtpConnectFailedError extends FtpError {
  name: string = "FtpConnectFailedError";

  constructor(message: string, stack?: string | undefined, cause?: Error) {
    super(message, stack, cause);
  }
}