import { StringEncoding } from "../StringEncoding";
import { FtpTlsOptions } from "./socket/FtpTlsOptions";

export interface AccessOptions {
  /** Host the client should connect to. Optional, default is "localhost". */
  readonly host?: string;

  /** Port the client should connect to. Optional, default is 21. */
  readonly port?: number;

  /** Username to use for login. Optional, default is "anonymous". */
  readonly user?: string;

  /** Password to use for login. Optional, default is "guest". */
  readonly password?: string;

  /** Use FTPS over TLS. Optional, default is false. True is preferred explicit TLS, "implicit" supports legacy, non-standardized implicit TLS. */
  readonly secureMode?: boolean | "implicit";
  readonly tlsOptions?: FtpTlsOptions;
  readonly encoding?: StringEncoding;
  readonly listHiddenFile?: boolean;
}