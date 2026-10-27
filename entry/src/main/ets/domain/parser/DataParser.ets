/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import { SatOrbitalData } from '../predict/OrbitalData';
import { SatRadio } from '../model/SatRadio';

const alpha5Alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ';

type TransponderRow = Record<string, Object | null | undefined>;

export class SatDataParser {
  parseTLEStream(text: string): SatOrbitalData[] {
    const lines = text.replace(/\r/g, '').split('\n');
    const result: SatOrbitalData[] = [];
    for (let i = 0; i + 2 < lines.length; i += 3) {
      const line0 = lines[i].trim();
      const line1 = lines[i + 1].trim();
      const line2 = lines[i + 2].trim();
      if (line1.startsWith('1') && line2.startsWith('2')) {
        const parsed = this.parseTLE([line0, line1, line2]);
        if (parsed !== null) {
          result.push(parsed);
        }
      }
    }
    return result;
  }

  parseCSVStream(text: string): SatOrbitalData[] {
    const lines = text.replace(/\r/g, '').split('\n');
    if (lines.length === 0) {
      return [];
    }
    const columns = this.parseCSVColumns(lines[0]);
    const result: SatOrbitalData[] = [];
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].trim().length === 0) {
        continue;
      }
      const parsed = this.parseCSV(lines[i].split(','), columns);
      if (parsed !== null) {
        result.push(parsed);
      }
    }
    return result;
  }

  /** Parse the transponder JSON array served by the built-in mirror (trans.json). */
  parseTransponderJSON(text: string): SatRadio[] {
    const result: SatRadio[] = [];
    try {
      const obj: Object = JSON.parse(text);
      if (!(obj instanceof Array)) {
        return result;
      }
      const arr: Object[] = obj as Object[];
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i];
        if (typeof item !== 'object' || item === null) {
          continue;
        }
        const row = item as TransponderRow;
        const r: SatRadio | null = this.parseTransponderRow(row);
        if (r !== null) {
          result.push(r);
        }
      }
    } catch (e) {
      console.warn(`Transponder JSON parsing exception: ${JSON.stringify(e)}`);
    }
    return result;
  }

  private parseTransponderRow(row: TransponderRow): SatRadio | null {
    if (row['uuid'] === undefined || row['uuid'] === null) {
      return null;
    }
    const uuid: string = typeof row['uuid'] === 'string' ? row['uuid'] as string : '';
    const info: string = typeof row['description'] === 'string' ? row['description'] as string : '';
    let isAlive = true;
    if (typeof row['alive'] === 'boolean') {
      isAlive = row['alive'] as boolean;
    }
    const downlinkLow: number | null = this.jsonLong(row['downlink_low']);
    const downlinkHigh: number | null = this.jsonLong(row['downlink_high']);
    const downlinkMode: string | null = this.jsonStr(row['mode']);
    const uplinkLow: number | null = this.jsonLong(row['uplink_low']);
    const uplinkHigh: number | null = this.jsonLong(row['uplink_high']);
    const uplinkMode: string | null = this.jsonStr(row['uplink_mode']);
    let isInverted = false;
    if (typeof row['invert'] === 'boolean') {
      isInverted = row['invert'] as boolean;
    }
    const catnum: number | null = this.jsonNumber(row['norad_cat_id']);
    return new SatRadio(uuid, info, isAlive, downlinkLow, downlinkHigh, downlinkMode,
      uplinkLow, uplinkHigh, uplinkMode, isInverted, catnum);
  }

  private jsonLong(v: Object | null | undefined): number | null {
    return typeof v === 'number' ? v as number : null;
  }

  private jsonNumber(v: Object | null | undefined): number | null {
    return typeof v === 'number' ? v as number : null;
  }

  private jsonStr(v: Object | null | undefined): string | null {
    return typeof v === 'string' ? v as string : null;
  }

  private parseCSV(values: string[], columns: Map<string, number>): SatOrbitalData | null {
    try {
      const valueFn = (column: string): string => values[columns.get(column) ?? -1].trim();
      const optionalValue = (column: string): number => {
        const index = columns.has(column) ? columns.get(column) ?? 0 : -1;
        if (index < 0 || index >= values.length) {
          return 0.0;
        }
        const num = Number(values[index].trim());
        return Number.isNaN(num) ? 0.0 : num;
      };
      return new SatOrbitalData(
        valueFn('OBJECT_NAME'),
        this.parseTimestamp(valueFn('EPOCH')),
        Number(valueFn('MEAN_MOTION')),
        Number(valueFn('ECCENTRICITY')),
        Number(valueFn('INCLINATION')),
        Number(valueFn('RA_OF_ASC_NODE')),
        Number(valueFn('ARG_OF_PERICENTER')),
        Number(valueFn('MEAN_ANOMALY')),
        this.parseCatnum(valueFn('NORAD_CAT_ID')),
        optionalValue('BSTAR'),
        optionalValue('MEAN_MOTION_DOT')
      );
    } catch (e) {
      console.warn(`CSV parsing exception: ${JSON.stringify(e)}`);
      return null;
    }
  }

  private parseCSVColumns(headerLine: string): Map<string, number> {
    const columns = new Map<string, number>();
    const cols = headerLine.split(',');
    for (let i = 0; i < cols.length; i++) {
      columns.set(cols[i].trim().replace(/"/g, '').toUpperCase(), i);
    }
    if (columns.has('NORAD_CAT_ID')) {
      return columns;
    }
    const fallback = new Map<string, number>();
    fallback.set('OBJECT_NAME', 0);
    fallback.set('EPOCH', 2);
    fallback.set('MEAN_MOTION', 3);
    fallback.set('ECCENTRICITY', 4);
    fallback.set('INCLINATION', 5);
    fallback.set('RA_OF_ASC_NODE', 6);
    fallback.set('ARG_OF_PERICENTER', 7);
    fallback.set('MEAN_ANOMALY', 8);
    fallback.set('NORAD_CAT_ID', 11);
    fallback.set('BSTAR', 14);
    fallback.set('MEAN_MOTION_DOT', 15);
    return fallback;
  }

  private parseTimestamp(timestamp: string): number {
    const year = Number(timestamp.substring(0, 4));
    const month = Number(timestamp.substring(5, 7));
    const dayOfMonth = Number(timestamp.substring(8, 10));
    const hours = Number(timestamp.substring(11, 13));
    const minutes = Number(timestamp.substring(14, 16));
    let secondsStr = timestamp.substring(17);
    let seconds = 0.0;
    for (let i = 0; i < secondsStr.length; i++) {
      const ch = secondsStr.charAt(i);
      if (ch >= '0' && ch <= '9' || ch === '.') {
        continue;
      }
      secondsStr = secondsStr.substring(0, i);
      break;
    }
    seconds = Number(secondsStr);
    const dayFraction = (hours * 3600 + minutes * 60 + seconds) / 86400.0;
    return (year % 100) * 1000 + this.getDayOfYear(year, month, dayOfMonth) + dayFraction;
  }

  private parseCatnum(value: string): number {
    const catnum = value.trim();
    const first = catnum.charAt(0);
    if (first >= '0' && first <= '9') {
      return Number(catnum);
    }
    const alphaIndex = alpha5Alphabet.indexOf(first.toUpperCase());
    if (alphaIndex < 0) {
      throw new Error(`Unknown Alpha-5 catalog number: ${catnum}`);
    }
    return (alphaIndex + 10) * 10000 + Number(catnum.substring(1).trim());
  }

  private parseTLE(tle: string[]): SatOrbitalData | null {
    try {
      const line1 = tle[1];
      const line2 = tle[2];
      let name = tle[0].trim();
      if (name.startsWith('0 ')) {
        name = name.substring(2).trim();
      }
      const ndotStr = line1.substring(33, 43).trim();
      return new SatOrbitalData(
        name,
        Number(line1.substring(18, 32)),
        Number(line2.substring(52, 63)),
        Number(line2.substring(26, 33)) / 1e7,
        Number(line2.substring(8, 16)),
        Number(line2.substring(17, 25)),
        Number(line2.substring(34, 42)),
        Number(line2.substring(43, 51)),
        this.parseCatnum(line1.substring(2, 7)),
        1e-5 * Number(line1.substring(53, 59)) / Math.pow(10, Number(line1.substring(60, 61))),
        ndotStr.length > 0 ? Number(ndotStr) : 0.0
      );
    } catch (e) {
      console.warn(`TLE parsing exception: ${JSON.stringify(e)}`);
      return null;
    }
  }

  isLeapYear(year: number): boolean {
    return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  }

  getDayOfYear(year: number, month: number, dayOfMonth: number): number {
    const daysInMonth = [31, this.isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let sum = 0;
    for (let i = 0; i < month - 1; i++) {
      sum += daysInMonth[i];
    }
    return sum + dayOfMonth;
  }
}