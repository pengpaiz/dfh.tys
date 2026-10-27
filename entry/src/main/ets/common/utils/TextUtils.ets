/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * HarmonyOS text/byte helpers.
 */

export function bytesToString(bytes: Uint8Array): string {
  let result = '';
  const chunk = 8192;
  for (let i = 0; i < bytes.length; i += chunk) {
    const end = i + chunk < bytes.length ? i + chunk : bytes.length;
    let part = '';
    for (let j = i; j < end; j++) {
      part += String.fromCharCode(bytes[j]);
    }
    result += part;
  }
  return result;
}

export function stringToBytes(s: string): Uint8Array {
  const bytes = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    bytes[i] = s.charCodeAt(i) & 0xff;
  }
  return bytes;
}