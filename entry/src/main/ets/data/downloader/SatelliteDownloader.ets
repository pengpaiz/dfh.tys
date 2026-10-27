/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * HarmonyOS data layer: 卫星/转发器数据下载。
 *
 * 本应用为「离线优先 / 单机」：内置快照即开即用，默认不联网。
 * 只有在设置里填写了自定义数据源地址、并由用户手动触发更新时才会发起网络请求。
 * 不含任何内置/默认远程地址。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SatDataParser } from '../../domain/parser/DataParser';
import { SatOrbitalData } from '../../domain/predict/OrbitalData';
import { SatRadio } from '../../domain/model/SatRadio';
import { bytesToString } from '../../common/utils/TextUtils';

export class SatelliteDownloadResult {
  dataList: SatOrbitalData[];
  count: number;
  /** 本次数据实际来自哪个地址（用于在设置页显示"当前使用的源"） */
  sourceUrl: string;
  /** 用户自定义地址本次是否失败（用于设置页展示自定义源的成功/失败） */
  customFailed: boolean;

  constructor(dataList: SatOrbitalData[], sourceUrl: string = '', customFailed: boolean = false) {
    this.dataList = dataList;
    this.count = dataList.length;
    this.sourceUrl = sourceUrl;
    this.customFailed = customFailed;
  }
}

export class TransponderDownloadResult {
  transponders: SatRadio[];
  count: number;

  constructor(transponders: SatRadio[]) {
    this.transponders = transponders;
    this.count = transponders.length;
  }
}

export class SatelliteDownloader {
  private parser: SatDataParser = new SatDataParser();

  /**
   * 只使用用户自定义地址下载。
   * 未配置地址时直接抛错（不联网）——本应用可离线使用，联网更新是可选项。
   */
  async downloadWithFallback(customUrl: string = ''): Promise<SatelliteDownloadResult> {
    const custom = customUrl.trim();
    if (custom.length === 0) {
      throw new Error('no-source');
    }
    const result = await this.downloadAuto(custom);
    if (result.count === 0) {
      throw new Error(`empty result: ${custom}`);
    }
    return result;
  }

  /** 判断 URL 是否可下载的 HTTP(S) 地址。 */
  static isUsableUrl(url: string): boolean {
    const u = url.trim().toLowerCase();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /**
   * 自动识别格式下载：按行内含逗号判定 CSV，否则按 TLE 三行解析；
   * 解析为空时再试另一种，兼容用户自建源。
   */
  async downloadAuto(url: string): Promise<SatelliteDownloadResult> {
    const text = await this.fetchText(url);
    const looksCsv = SatelliteDownloader.looksLikeCsv(text);
    const first = looksCsv ? this.parser.parseCSVStream(text) : this.parser.parseTLEStream(text);
    if (first.length > 0) {
      return new SatelliteDownloadResult(first, url);
    }
    const second = looksCsv ? this.parser.parseTLEStream(text) : this.parser.parseCSVStream(text);
    return new SatelliteDownloadResult(second, url);
  }

  /** 采样前若干非空行，超过半数含逗号且含字母，则认为是 CSV。 */
  private static looksLikeCsv(text: string): boolean {
    const lines = text.split('\n');
    let checked = 0;
    let comma = 0;
    for (let i = 0; i < lines.length && checked < 5; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      checked++;
      if (line.indexOf(',') >= 0) {
        comma++;
      }
    }
    return checked > 0 && comma * 2 > checked;
  }

  /** Parse a local TLE text snapshot (e.g. bundled in rawfile). */
  parseTLEText(text: string): SatelliteDownloadResult {
    return new SatelliteDownloadResult(this.parser.parseTLEStream(text));
  }

  /** Parse a local transponder JSON text snapshot. */
  parseTransponderText(text: string): TransponderDownloadResult {
    return new TransponderDownloadResult(this.parser.parseTransponderJSON(text));
  }

  /** 下载转发器数据：同样只使用用户自定义地址，未配置则不联网。 */
  async downloadTransponders(url: string): Promise<TransponderDownloadResult> {
    const target = url.trim();
    if (target.length === 0) {
      throw new Error('no-source');
    }
    const text = await this.fetchText(target);
    const list = this.parser.parseTransponderJSON(text);
    return new TransponderDownloadResult(list);
  }

  private fetchText(url: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const httpRequest = http.createHttp();
      httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 20000,
        readTimeout: 60000,
        header: { 'Accept': '*/*', 'User-Agent': 'Look4Sat-Harmony/1.0' }
      }, (err: BusinessError, data: http.HttpResponse) => {
        httpRequest.destroy();
        if (err) {
          reject(err);
          return;
        }
        const code = data.responseCode;
        if (code !== 200) {
          reject(new Error(`HTTP ${code}`));
          return;
        }
        const result: Object = data.result;
        resolve(this.resultToString(result));
      });
    });
  }

  private resultToString(result: Object): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return bytesToString(new Uint8Array(result));
    }
    return String(result);
  }
}