/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import { SatGeoPos } from '../predict/GeoPos';
import { roundDouble } from '../../common/utils/MathUtils';

export function qthToPosition(locator: string): SatGeoPos | null {
  const trimmedQth = locator.substring(0, 6);
  if (!isValidLocator(trimmedQth)) {
    return null;
  }
  const lonFirst = (trimmedQth.charCodeAt(0) - 65) * 20;
  const latFirst = (trimmedQth.charCodeAt(1) - 65) * 10;
  const lonSecond = (trimmedQth.charCodeAt(2) - 48) * 2;
  const latSecond = trimmedQth.charCodeAt(3) - 48;
  const lonThird = (lowercaseCode(trimmedQth.charCodeAt(4)) - 97) / 12.0 + (1.0 / 24.0) - 180;
  const latThird = (lowercaseCode(trimmedQth.charCodeAt(5)) - 97) / 24.0 + (1.0 / 48.0) - 90;
  const longitude = roundDouble(lonFirst + lonSecond + lonThird, 4);
  const latitude = roundDouble(latFirst + latSecond + latThird, 4);
  return new SatGeoPos(latitude, longitude);
}

export function positionToQth(latitude: number, longitude: number): string | null {
  if (!isValidPosition(latitude, longitude)) {
    return null;
  }
  const newLongitude = longitude > 180.0 ? longitude : longitude + 180;
  const newLatitude = latitude + 90;
  const lonFirst = String.fromCharCode(Math.floor(65 + (newLongitude / 20)));
  const latFirst = String.fromCharCode(Math.floor(65 + (newLatitude / 10)));
  const lonSecond = Math.floor((newLongitude / 2) % 10).toString();
  const latSecond = Math.floor(newLatitude % 10).toString();
  const lonThird = String.fromCharCode(Math.floor(65 + (newLongitude % 2) * 12)).toLowerCase();
  const latThird = String.fromCharCode(Math.floor(65 + (newLatitude % 1) * 24)).toLowerCase();
  return `${lonFirst}${latFirst}${lonSecond}${latSecond}${lonThird}${latThird}`;
}

function isValidPosition(lat: number, lon: number): boolean {
  return (lat >= -90.0 && lat <= 90.0) && (lon >= -180.0 && lon <= 360.0);
}

function lowercaseCode(code: number): number {
  return (code >= 65 && code <= 90) ? code + 32 : code;
}

function isValidLocator(locator: string): boolean {
  const pattern = /^[a-xA-X][a-xA-X]\d\d[a-xA-X][a-xA-X]$/;
  return pattern.test(locator);
}