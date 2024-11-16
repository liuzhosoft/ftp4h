/*
 * Copyright (C) 2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { GBK } from "./gbk/gbk";
import { buffer } from "@kit.ArkTS";

export type StringEncoding =
  "utf8" | "ascii" | "utf-8" | "utf16le" | "ucs2" | "ucs-2" |
  "base64" | "latin1" | "binary" | "hex" | "gbk" | undefined;


export namespace CharsetUtil {
  export function decode(data: ArrayBuffer, encoding: StringEncoding): string {
    if (encoding === "gbk") {
      return GBK.decode(new Uint8Array(data));
    } else {
      return buffer.from(data).toString(encoding);
    }
  }
}