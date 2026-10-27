/*
 * Look4Sat. Shared satellite palette.
 * Deliberately avoids the app theme blue (#538EF4) and other UI accents
 * (footprint blue, live yellow, station/track red) so satellite markers
 * stay clearly distinguishable from UI elements.
 * 也不使用偏黄的橙黄/土黄（#F39C12/#D4AC0D 之类）：在过境/日历列表里
 * 卫星名与时间会用该色，黄色容易被误读成"高亮/当前"。
 */
export const SAT_COLORS: string[] = [
  '#E67E22', '#2ECC71', '#8E44AD', '#16A085', '#00BCD4', '#27AE60',
  '#9B59B6', '#C2185B', '#FF8A65', '#E040FB', '#7F8C8D', '#6C3483'
];
