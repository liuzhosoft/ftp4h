export interface FtpReadStream {
  read(): Promise<ArrayBuffer>;

  close(): void;
}