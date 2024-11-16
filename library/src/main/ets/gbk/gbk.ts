import { gbk_data_arr } from "./gbk_data";

const arr_index = 0x8140; //33088;

class _GBK {
  private readonly gbk_us: number[];

  constructor(gbk_us: number[]) {
    this.gbk_us = gbk_us;
  }

  decode(bytes: Uint8Array) {
    let str = "";
    for (let n = 0, max = bytes.length; n < max; n++) {
      let code = bytes[n] & 0xff;
      if (code > 0x80 && n + 1 < max) {
        let code1 = bytes[n + 1] & 0xff;
        if (code1 >= 0x40) {
          code = this.gbk_us[(code << 8 | code1) - arr_index];
          n++;
        }
      }
      str += String.fromCharCode(code);
    }
    return str;
  }

  encode(str: string) {
    let gbk: number[] = [];
    let wh = "?".charCodeAt(0); //gbk中没有的字符的替换符
    for (let i = 0; i < str.length; i++) {
      let charcode = str.charCodeAt(i);
      if (charcode < 0x80) {
        gbk.push(charcode);
      } else {
        let gcode = this.gbk_us.indexOf(charcode);
        if (~gcode) {
          gcode += arr_index;
          gbk.push(0xFF & (gcode >> 8), 0xFF & gcode);
        } else {
          gbk.push(wh);
        }
      }
    }
    return gbk;
  }
};


export const GBK = new _GBK(gbk_data_arr);
