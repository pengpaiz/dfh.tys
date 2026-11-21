/*
 * Look4Sat. 收藏的卫星（与「已选择」相互独立）。
 *
 * 已选择 = 参与过境预报的卫星；收藏 = 用户标记的常用卫星，
 * 用于在卫星页快速筛选（收藏夹），不影响预报计算。
 * 与 SelectedSats 一样放在 AppStorage，保证跨标签页同步、重启后仍在。
 */

const FAV_KEY = 'favorite_cats';
const FAV_VERSION_KEY = 'favorite_version';

export class Favorites {
  static init(): void {
    PersistentStorage.persistProp(FAV_KEY, new Array<number>());
    PersistentStorage.persistProp(FAV_VERSION_KEY, 0);
  }

  static getCats(): number[] {
    const cats = AppStorage.get<number[]>(FAV_KEY);
    return cats === undefined ? [] : cats;
  }

  static isFavorite(catnum: number): boolean {
    return Favorites.getCats().indexOf(catnum) >= 0;
  }

  static count(): number {
    return Favorites.getCats().length;
  }

  static toggle(catnum: number): void {
    const cats = Favorites.getCats();
    const idx = cats.indexOf(catnum);
    if (idx >= 0) {
      cats.splice(idx, 1);
    } else {
      cats.push(catnum);
    }
    // 存一份新数组，保证 AppStorage / @StorageLink 能感知变化
    AppStorage.setOrCreate<number[]>(FAV_KEY, Array.from(cats));
    const v = AppStorage.get<number>(FAV_VERSION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(FAV_VERSION_KEY, v + 1);
  }

  static clear(): void {
    AppStorage.setOrCreate<number[]>(FAV_KEY, []);
    const v = AppStorage.get<number>(FAV_VERSION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(FAV_VERSION_KEY, v + 1);
  }
}
