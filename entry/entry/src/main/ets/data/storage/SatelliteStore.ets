/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * HarmonyOS data layer: in-memory store + persistence + LazyForEach data source.
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SatOrbitalData } from '../../domain/predict/OrbitalData';
import { SatRadio } from '../../domain/model/SatRadio';
import { bytesToString, stringToBytes } from '../../common/utils/TextUtils';

const STORE_FILE = 'satellites.jsonl';
const TRANSPONDER_FILE = 'transponders.json';
/** 落盘分片行数与每片之间让帧时长：避免上万条一次性阻塞主线程 */
const SAVE_CHUNK_ROWS = 2000;
const SAVE_YIELD_MS = 16;

export class SatelliteStore {
  private list: SatOrbitalData[] = [];
  private transponders: SatRadio[] = [];
  private context: common.Context | null = null;
  /** catnum → 卫星 的惰性索引（每次数据变更后置空重建），避免每次线性查找 1.6 万条 */
  private byCatIndex: Map<number, SatOrbitalData> | null = null;
  /** catnum → 转发器列表 的惰性索引 */
  private transByCatIndex: Map<number, SatRadio[]> | null = null;

  setContext(ctx: common.Context): void {
    this.context = ctx;
  }

  getDataSource(): SatelliteDataSource {
    return new SatelliteDataSource(this.list);
  }

  getAll(): SatOrbitalData[] {
    return this.list;
  }

  getTransponders(): SatRadio[] {
    return this.transponders;
  }

  getTranspondersFor(satCatnum: number): SatRadio[] {
    if (this.transByCatIndex === null) {
      const index: Map<number, SatRadio[]> = new Map<number, SatRadio[]>();
      for (let i = 0; i < this.transponders.length; i++) {
        const t = this.transponders[i];
        if (t.catnum === null) {
          continue;
        }
        let bucket = index.get(t.catnum);
        if (bucket === undefined) {
          bucket = [];
          index.set(t.catnum, bucket);
        }
        bucket.push(t);
      }
      this.transByCatIndex = index;
    }
    const list = this.transByCatIndex.get(satCatnum);
    return list === undefined ? [] : list;
  }

  setTransponders(list: SatRadio[]): void {
    this.transponders = list;
    this.transByCatIndex = null;
  }

  replaceAll(newList: SatOrbitalData[]): void {
    this.list = newList;
    this.byCatIndex = null;
  }

  getByCatnum(catnum: number): SatOrbitalData | null {
    if (this.byCatIndex === null) {
      const index: Map<number, SatOrbitalData> = new Map<number, SatOrbitalData>();
      for (let i = 0; i < this.list.length; i++) {
        const s = this.list[i];
        if (!index.has(s.catnum)) {
          index.set(s.catnum, s);
        }
      }
      this.byCatIndex = index;
    }
    const found = this.byCatIndex.get(catnum);
    return found === undefined ? null : found;
  }

  /** Drop older duplicates, keeping the freshest epoch per NORAD id. */
  dedupeKeepFreshest(): void {
    const byCat = new Map<number, SatOrbitalData>();
    for (let i = 0; i < this.list.length; i++) {
      const s = this.list[i];
      const existing = byCat.get(s.catnum);
      if (existing === undefined || s.epochDaynum > existing.epochDaynum) {
        byCat.set(s.catnum, s);
      }
    }
    this.list = Array.from(byCat.values());
    this.byCatIndex = null;
  }

  async load(): Promise<void> {
    if (this.context === null) {
      return;
    }
    // 先读小体量的转发器，保证过境详情频率能第一时间就绪
    try {
      const path = `${this.context.filesDir}/${TRANSPONDER_FILE}`;
      if (fs.accessSync(path)) {
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        try {
          const stat = fs.statSync(file.fd);
          const buffer = new ArrayBuffer(stat.size);
          fs.readSync(file.fd, buffer);
          const content = bytesToString(new Uint8Array(buffer));
          this.transponders = this.deserializeTransponders(content);
          this.transByCatIndex = null;
        } finally {
          fs.closeSync(file);
        }
      }
    } catch (e) {
      console.warn(`SatelliteStore.load transponders failed: ${JSON.stringify(e)}`);
    }
    try {
      const path = `${this.context.filesDir}/${STORE_FILE}`;
      if (fs.accessSync(path)) {
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        try {
          const stat = fs.statSync(file.fd);
          const buffer = new ArrayBuffer(stat.size);
          fs.readSync(file.fd, buffer);
          const content = bytesToString(new Uint8Array(buffer));
          this.list = this.deserialize(content);
          this.byCatIndex = null;
        } finally {
          fs.closeSync(file);
        }
      }
    } catch (e) {
      console.warn(`SatelliteStore.load failed: ${JSON.stringify(e)}`);
    }
  }

  private deserializeTransponders(content: string): SatRadio[] {
    const result: SatRadio[] = [];
    const trimmed = content.trim();
    if (trimmed.startsWith('[')) {
      return this.parseTransponderArray(trimmed);
    }
    const lines = trimmed.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      try {
        const obj = JSON.parse(line) as TransponderRow;
        const r = this.buildSatRadio(obj);
        if (r !== null) {
          result.push(r);
        }
      } catch (e) {
        // skip malformed line
      }
    }
    return result;
  }

  private parseTransponderArray(text: string): SatRadio[] {
    const result: SatRadio[] = [];
    try {
      const obj: Object = JSON.parse(text);
      if (obj instanceof Array) {
        const arr: Object[] = obj as Object[];
        for (let i = 0; i < arr.length; i++) {
          const r = this.buildSatRadio(arr[i] as TransponderRow);
          if (r !== null) {
            result.push(r);
          }
        }
        return result;
      }
    } catch (e) {
      // 超大一次性 JSON.parse 可能失败，退回按顶层逗号切分
    }
    const first = text.indexOf('[');
    const last = text.lastIndexOf(']');
    if (first < 0 || last < 0 || last <= first) {
      return result;
    }
    const parts = this.splitTransponderParts(text.substring(first + 1, last));
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i].trim();
      if (part.length === 0) {
        continue;
      }
      try {
        const obj = JSON.parse(part) as TransponderRow;
        const r = this.buildSatRadio(obj);
        if (r !== null) {
          result.push(r);
        }
      } catch (e) {
        // skip malformed object
      }
    }
    return result;
  }

  private splitTransponderParts(inner: string): string[] {
    const parts: string[] = [];
    let depth = 0;
    let inStr = false;
    let cur = '';
    for (let i = 0; i < inner.length; i++) {
      const ch = inner.charAt(i);
      if (inStr) {
        cur += ch;
        if (ch === '"' && inner.charAt(i - 1) !== '\\') {
          inStr = false;
        }
        continue;
      }
      if (ch === '"') {
        inStr = true;
        cur += ch;
        continue;
      }
      if (ch === '{' || ch === '[') {
        depth++;
        cur += ch;
        continue;
      }
      if (ch === '}' || ch === ']') {
        depth--;
        cur += ch;
        continue;
      }
      if (ch === ',' && depth === 0) {
        parts.push(cur);
        cur = '';
        continue;
      }
      cur += ch;
    }
    if (cur.trim().length > 0) {
      parts.push(cur);
    }
    return parts;
  }

  private buildSatRadio(row: TransponderRow): SatRadio | null {
    if (row['uuid'] === undefined) {
      return null;
    }
    return new SatRadio(
      String(row['uuid']),
      this.stringOr(row['description'], ''),
      typeof row['alive'] === 'boolean' ? row['alive'] as boolean : true,
      this.numberOrNull(row['downlink_low']),
      this.numberOrNull(row['downlink_high']),
      this.stringOrNull(row['mode']),
      this.numberOrNull(row['uplink_low']),
      this.numberOrNull(row['uplink_high']),
      this.stringOrNull(row['uplink_mode']),
      typeof row['invert'] === 'boolean' ? row['invert'] as boolean : false,
      this.numberOrNull(row['norad_cat_id'])
    );
  }

  private stringOr(v: Object | null | undefined, fallback: string): string {
    return typeof v === 'string' ? v as string : fallback;
  }

  private stringOrNull(v: Object | null | undefined): string | null {
    return typeof v === 'string' ? v as string : null;
  }

  private numberOrNull(v: Object | null | undefined): number | null {
    return typeof v === 'number' ? v as number : null;
  }

  async save(): Promise<void> {
    if (this.context === null) {
      return;
    }
    try {
      const path = `${this.context.filesDir}/${STORE_FILE}`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        // 分片序列化 + 分片写入并让帧：上万条一次性 stringify+写盘会长时间阻塞主线程，
        // 表现为启动后几秒内点哪都卡。
        const total = this.list.length;
        let start = 0;
        while (start < total) {
          const end = Math.min(total, start + SAVE_CHUNK_ROWS);
          const lines: string[] = [];
          for (let i = start; i < end; i++) {
            lines.push(this.serializeOne(this.list[i]));
          }
          const buffer = stringToBytes(`${lines.join('\n')}\n`);
          fs.writeSync(file.fd, buffer.buffer);
          start = end;
          if (start < total) {
            await SatelliteStore.yieldFrame();
          }
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      console.warn(`SatelliteStore.save failed: ${JSON.stringify(e)}`);
    }
  }

  async saveTransponders(): Promise<void> {
    if (this.context === null) {
      return;
    }
    try {
      const path = `${this.context.filesDir}/${TRANSPONDER_FILE}`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        // 与卫星数据一样分片序列化 + 分片写入并让帧，避免上万条转发器一次性 stringify+写盘卡住主线程。
        const total = this.transponders.length;
        let start = 0;
        while (start < total) {
          const end = Math.min(total, start + SAVE_CHUNK_ROWS);
          const lines: string[] = [];
          for (let i = start; i < end; i++) {
            lines.push(this.serializeTransponderOne(this.transponders[i]));
          }
          const buffer = stringToBytes(`${lines.join('\n')}\n`);
          fs.writeSync(file.fd, buffer.buffer);
          start = end;
          if (start < total) {
            await SatelliteStore.yieldFrame();
          }
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      console.warn(`SatelliteStore.saveTransponders failed: ${JSON.stringify(e)}`);
    }
  }

  /** 单条转发器序列化（分片保存时逐条调用） */
  private serializeTransponderOne(t: SatRadio): string {
    return JSON.stringify({
      'uuid': t.uuid, 'description': t.info, 'alive': t.isAlive,
      'downlink_low': t.downlinkLow, 'downlink_high': t.downlinkHigh, 'mode': t.downlinkMode,
      'uplink_low': t.uplinkLow, 'uplink_high': t.uplinkHigh, 'uplink_mode': t.uplinkMode,
      'invert': t.isInverted, 'norad_cat_id': t.catnum
    });
  }

  private serialize(list: SatOrbitalData[]): string {
    const lines: string[] = [];
    for (let i = 0; i < list.length; i++) {
      lines.push(this.serializeOne(list[i]));
    }
    return lines.join('\n');
  }

  /** 单条序列化（分片保存时逐条调用） */
  private serializeOne(s: SatOrbitalData): string {
    return JSON.stringify({
      name: s.name, epoch: s.epoch, meanmo: s.meanmo, eccn: s.eccn, incl: s.incl,
      raan: s.raan, argper: s.argper, meanan: s.meanan, catnum: s.catnum, bstar: s.bstar, ndot: s.ndot
    });
  }

  /** 让帧：把主线程还给渲染 */
  private static yieldFrame(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, SAVE_YIELD_MS);
    });
  }

  private deserialize(content: string): SatOrbitalData[] {
    const result: SatOrbitalData[] = [];
    const lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      try {
        const obj = JSON.parse(line) as StoreRow;
        result.push(new SatOrbitalData(obj.name, obj.epoch, obj.meanmo, obj.eccn, obj.incl, obj.raan,
          obj.argper, obj.meanan, obj.catnum, obj.bstar, obj.ndot));
      } catch (e) {
        // skip malformed line
      }
    }
    return result;
  }
}

interface StoreRow {
  name: string;
  epoch: number;
  meanmo: number;
  eccn: number;
  incl: number;
  raan: number;
  argper: number;
  meanan: number;
  catnum: number;
  bstar: number;
  ndot: number;
}

type TransponderRow = Record<string, Object | null | undefined>;

interface SerializedTransponder {
  uuid: string;
  description: string;
  alive: boolean;
  downlink_low: number | null;
  downlink_high: number | null;
  mode: string | null;
  uplink_low: number | null;
  uplink_high: number | null;
  uplink_mode: string | null;
  invert: boolean;
  norad_cat_id: number | null;
}

/** Data source driving LazyForEach for the satellite list. */
export class SatelliteDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private dataArr: SatOrbitalData[];

  constructor(list: SatOrbitalData[]) {
    this.dataArr = list;
  }

  totalCount(): number {
    return this.dataArr.length;
  }

  getData(index: number): SatOrbitalData {
    return this.dataArr[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  notifyDatasetChanged(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  notifyDataAdd(index: number): void {
    for (const listener of this.listeners) {
      listener.onDataAdd(index);
    }
  }

  notifyDataDelete(index: number): void {
    for (const listener of this.listeners) {
      listener.onDataDelete(index);
    }
  }

  setData(list: SatOrbitalData[]): void {
    this.dataArr = list;
    this.notifyDatasetChanged();
  }
}