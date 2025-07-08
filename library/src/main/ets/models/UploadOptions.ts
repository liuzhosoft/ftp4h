export interface UploadOptions {
  /** Offset in the local file to start uploading from. */
  localStart?: number;

  /** Final byte position to include in upload from the local file. */
  localEndInclusive?: number;
}