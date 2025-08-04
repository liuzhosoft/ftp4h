export interface FtpResponse {
  /** FTP response code */
  readonly code: number;

  /** Whole response including response code */
  readonly message: string;
  readonly multiLineResponse?: FtpResponse[];
}