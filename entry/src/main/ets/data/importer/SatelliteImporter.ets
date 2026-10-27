/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * HarmonyOS data layer: import TLE/OMM text files via system Picker.
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { SatDataParser } from '../../domain/parser/DataParser';
import { SatOrbitalData } from '../../domain/predict/OrbitalData';
import { bytesToString } from '../../common/utils/TextUtils';

export class SatelliteImportResult {
  dataList: SatOrbitalData[];
  fileName: string;
  count: number;

  constructor(dataList: SatOrbitalData[], fileName: string) {
    this.dataList = dataList;
    this.fileName = fileName;
    this.count = dataList.length;
  }
}

export class SatelliteImporter {
  private parser: SatDataParser = new SatDataParser();

  async pickAndParse(context: common.Context): Promise<SatelliteImportResult | null> {
    const option = new picker.DocumentSelectOptions();
    option.maxSelectNumber = 1;
    option.fileSuffixFilters = ['.txt', '.csv', '.tle'];
    const documentPicker = new picker.DocumentViewPicker(context);
    const selectResult = await documentPicker.select(option);
    if (!selectResult || selectResult.length === 0) {
      return null;
    }
    const uri: string = selectResult[0];
    const name: string = this.fileNameFromUri(uri);
    const text = await this.readUri(uri);
    return this.parseText(text, name);
  }

  private fileNameFromUri(uri: string): string {
    const idx = uri.lastIndexOf('/');
    return idx >= 0 ? uri.substring(idx + 1) : 'imported.txt';
  }

  private async readUri(uri: string): Promise<string> {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const size = stat.size;
      const buffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      return bytesToString(new Uint8Array(buffer));
    } finally {
      fs.closeSync(file);
    }
  }

  private parseText(text: string, name: string): SatelliteImportResult {
    if (text.includes('OBJECT_NAME') && text.includes('NORAD_CAT_ID')) {
      const list = this.parser.parseCSVStream(text);
      if (list.length > 0) {
        return new SatelliteImportResult(list, name);
      }
    }
    const tleList = this.parser.parseTLEStream(text);
    return new SatelliteImportResult(tleList, name);
  }
}