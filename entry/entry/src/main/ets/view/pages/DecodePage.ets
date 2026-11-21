/*
 * 「解码」标签页（P0）：文件选择 → Worker 持续扫描 VIS → 状态/进度显示（暂不出图）。
 *
 * 线程模型：DSP 全部在 Worker（entry/ets/workers/DecodeWorker.ets）；UI 只渲染与发指令。
 * 协议见 Worker 文件头。
 */

import { worker, MessageEvents } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { pickWavFile } from '../../service/FilePicker';
import type { PickedFile } from '../../service/FilePicker';
import { KEY_BAR_CLEARANCE, TAB_BAR_CLEARANCE } from '../../common/LayoutMetrics';
import { Logger } from '../../common/Logger';

const WORKER_PATH = 'entry/ets/workers/DecodeWorker.ets';

interface MetaMsg {
  type: string;
  sampleRate: number;
  channels: number;
  bits: number;
  frames: number;
  durationSec: number;
}

interface ProgressMsg {
  type: string;
  processedSec: number;
  totalSec: number;
  visCount: number;
}

interface VisMsg {
  type: string;
  visCode: number;
  modeName: string;
  atSec: number;
}

interface DoneMsg {
  type: string;
  visCount: number;
  stopped: boolean;
}

interface ErrorMsg {
  type: string;
  message: string;
}

interface RowsMsg {
  type: string;
  from: number;
  to: number;
}

interface CompleteMsg {
  type: string;
  width: number;
  height: number;
}

interface AbortMsg {
  type: string;
  reason: string;
  decodedLines: number;
}

interface InterruptedMsg {
  type: string;
  decodedLines: number;
}

/** 帧通知（二进制走沙箱文件，这里只有序号与已解行数） */
interface FrameMsg {
  type: string;
  seq: number;
  rowsDone: number;
}

/** 列表条目：imgId=解码图标识（收藏去重用），key=列表内唯一键，pm=像素图 */
interface GalleryShot {
  imgId: number;
  key: number;
  pm: image.PixelMap;
}

@Component
export struct DecodePage {
  @StorageProp(KEY_BAR_CLEARANCE) barClearance: number = TAB_BAR_CLEARANCE;

  @State fileName: string = '';
  @State scanning: boolean = false;
  @State statusText: string = '请选择一个 SSTV 录音文件（WAV）';
  @State modeText: string = '--';
  @State visCodeText: string = '--';
  @State speed: string = '4x';
  @State offsetHz: number = 0;

  @State sampleRate: number = 0;
  @State channels: number = 0;
  @State bits: number = 0;
  @State durationSec: number = 0;
  @State processedSec: number = 0;
  @State visCount: number = 0;
  /** 会话画廊：本次文件命中的 VIS 记录（小数组，可放 @State） */
  @State visLines: string[] = [];
  @State errorText: string = '';
  /** 当前这一张图已解出的行数（渐进显示进度） */
  @State decodedLines: number = 0;
  /** 渐进显示的图像（BGRA_8888）与其版本号（用于强制重绘） */
  @State pixelMap: image.PixelMap | undefined = undefined;
  @State frameSeq: number = 0;
  /** 已解码图片缩略图（最多 5 张，最新在后） */
  @State gallery: GalleryShot[] = [];
  /** 点击缩略图后的放大预览 */
  @State showPreview: boolean = false;
  @State previewPixel: image.PixelMap | undefined = undefined;
  /** 展览：点亮爱心的图片（双列展示，可点击放大） */
  @State exhibitions: GalleryShot[] = [];
  /** 爱心状态：当前大图 / 预览大图是否已点亮 */
  @State liveFav: boolean = false;
  @State previewFav: boolean = false;
  /** 当前大图是否已解码完成（爱心仅在完成后才显示/可收藏） */
  @State liveComplete: boolean = false;
  /** 当前大图 / 预览大图的“解码图 id”（收藏去重与持久化用；0=无效） */
  @State currentShotId: number = 0;
  @State previewShotId: number = 0;

  private workerInstance: worker.ThreadWorker | null = null;
  private snapTimer: number = -1;
  /** 沙箱内的实时帧文件（Worker 写，本页读） */
  private framePath: string = '';
  /** 保证同一时刻只有一次“读帧 → 建 PixelMap”在进行，避免并发堆积 */
  private loadingFrame: boolean = false;
  /** 延迟释放：上一帧 PixelMap 留一帧再释放，避免正在渲染时被释放导致崩溃 */
  private stalePixelMap: image.PixelMap | undefined = undefined;
  /** 解码完成时刻（用于“解码时间”命名）；0=尚未完成 */
  private decodeDoneAt: number = 0;
  /** 取消收藏时暂不释放、留到关闭预览时再释放的 PixelMap */
  private deferredRelease: image.PixelMap | undefined = undefined;
  /** 收藏切换重入保护（防止连点造成并发/重复） */
  private favBusy: boolean = false;
  /** 画廊条目自增 id */
  private shotSeq: number = 0;

  aboutToAppear(): void {
    // 加载持久化的“展览”收藏图（应用退出后仍保留）
    this.loadExhibitions();
  }

  aboutToDisappear(): void {
    this.stopSnapTimer();
    this.stopScan();
    if (this.pixelMap !== undefined) {
      this.pixelMap.release();
      this.pixelMap = undefined;
    }
    if (this.stalePixelMap !== undefined) {
      this.stalePixelMap.release();
      this.stalePixelMap = undefined;
    }
    // 释放画廊缩略图（previewPixel 只是引用其一，先置空再释放，避免重复释放）
    this.previewPixel = undefined;
    if (this.deferredRelease !== undefined) {
      this.deferredRelease.release();
      this.deferredRelease = undefined;
    }
    for (const g of this.gallery) {
      g.pm.release();
    }
    this.gallery = [];
    // 释放“展览”收藏图
    for (const e of this.exhibitions) {
      e.pm.release();
    }
    this.exhibitions = [];
    if (this.workerInstance !== null) {
      this.workerInstance.terminate();
      this.workerInstance = null;
    }
  }

  private startSnapTimer(): void {
    this.stopSnapTimer();
    this.snapTimer = setInterval((): void => {
      // 兜底轮询：正常情况下出帧由 Worker 按解码节奏主动推送，这里仅在长时间无帧时补一次
      if (this.workerInstance !== null && this.scanning && !this.loadingFrame) {
        this.workerInstance.postMessage(JSON.stringify({ cmd: 'snapshot', uri: '', coarseOffsetHz: this.offsetHz }));
      }
    }, 250);
  }

  private stopSnapTimer(): void {
    if (this.snapTimer >= 0) {
      clearInterval(this.snapTimer);
      this.snapTimer = -1;
    }
  }

  /** 读到帧通知后：从沙箱文件读整帧并重建 PixelMap（@State 变化必然重绘）。 */
  private async loadFrame(): Promise<void> {
    if (this.framePath === '' || this.loadingFrame) {
      return;
    }
    this.loadingFrame = true;
    try {
      const need = 320 * 240 * 4;
      const stat = fs.statSync(this.framePath);
      // 大小必须精确匹配：原子改名后应为满帧，否则视为写坏，跳过（不建 PixelMap，避免崩溃）
      if (stat.size !== need) {
        return;
      }
      const buf = new ArrayBuffer(need);
      const f = fs.openSync(this.framePath, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const opts: image.InitializationOptions = {
        size: { width: 320, height: 240 },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888
      };
      const next = await image.createPixelMap(buf, opts);
      // 延迟释放：只释放“上上帧”，当前帧与上一帧都保留，避免渲染用到已释放内存
      const stale = this.stalePixelMap;
      this.stalePixelMap = this.pixelMap;
      this.pixelMap = next;
      this.frameSeq++;
      if (stale !== undefined) {
        stale.release();
      }
      if (this.errorText.startsWith('帧渲染失败')) {
        this.errorText = '';
      }
    } catch (e) {
      const err: Error = e instanceof Error ? e : new Error(String(e));
      this.errorText = `帧渲染失败：${err.message}`;
    } finally {
      this.loadingFrame = false;
    }
  }

  private ensureWorker(): worker.ThreadWorker {
    if (this.workerInstance !== null) {
      return this.workerInstance;
    }
    const w = new worker.ThreadWorker(WORKER_PATH);
    w.onmessage = (e: MessageEvents): void => {
      this.onWorkerMessage(e.data as string);
    };
    // 注意：onerror 的参数类型由上下文推断（本 SDK 无全局 ErrorEvent 类型，勿显式标注）
    w.onerror = (err): void => {
      this.errorText = `Worker 异常：${err.message}`;
      this.scanning = false;
      this.statusText = '解码线程异常，已停止';
    };
    this.workerInstance = w;
    return w;
  }

  private onWorkerMessage(raw: string): void {
    let type = '';
    try {
      type = (JSON.parse(raw) as MetaMsg).type;
    } catch (e) {
      this.errorText = '无法解析 Worker 消息';
      return;
    }
    if (type === 'meta') {
      const m = JSON.parse(raw) as MetaMsg;
      this.sampleRate = m.sampleRate;
      this.channels = m.channels;
      this.bits = m.bits;
      this.durationSec = m.durationSec;
      this.statusText = '正在寻找 VIS…';
    } else if (type === 'progress') {
      const p = JSON.parse(raw) as ProgressMsg;
      this.processedSec = p.processedSec;
      this.visCount = p.visCount;
    } else if (type === 'vis') {
      const v = JSON.parse(raw) as VisMsg;
      // 新的图即将开始解码：把上一张“当前图”存入画廊（当前图不入缩略图）
      this.stashCurrent();
      this.liveFav = false;
      this.liveComplete = false;
      this.currentShotId = 0;
      // 注意：不要清 previewShotId！预览是独立视图，清掉会导致预览里“取消后再收藏”直接失效
      this.modeText = v.modeName;
      this.visCodeText = `${v.visCode}`;
      this.decodedLines = 0;
      this.visLines = this.visLines.concat([`${this.clock(v.atSec)}  ${v.modeName} (VIS ${v.visCode})`]);
      this.statusText = `已锁 VIS ${v.visCode} · 正在解码 ${v.modeName}…`;
    } else if (type === 'done') {
      const d = JSON.parse(raw) as DoneMsg;
      this.scanning = false;
      this.stopSnapTimer();
      this.visCount = d.visCount;
      this.statusText = d.visCount > 0
        ? `扫描完成：命中 ${d.visCount} 张图`
        : '扫描完成：未找到 VIS（请确认是 SSTV 录音，或调整频偏）';
    } else if (type === 'rows') {
      const r = JSON.parse(raw) as RowsMsg;
      this.decodedLines = r.to;
    } else if (type === 'frame') {
      const fm = JSON.parse(raw) as FrameMsg;
      if (fm.rowsDone >= 0) {
        this.decodedLines = fm.rowsDone;
      }
      this.loadFrame();
} else if (type === 'complete') {
      const c = JSON.parse(raw) as CompleteMsg;
      // 注意：完成后 Worker 仍在继续扫描剩余音频找下一张图，这里**不解除忙态**（等 'done'）
      this.decodedLines = c.height;
      this.decodeDoneAt = Date.now();
      this.liveComplete = true;
      this.currentShotId = Date.now(); // 解码完成后给这张图打上 id
      this.statusText = `解码完成：${c.width}×${c.height}`;
    } else if (type === 'abort') {
      const a = JSON.parse(raw) as AbortMsg;
      this.statusText = `${a.reason}（已解 ${a.decodedLines} 行，保留残图）`;
    } else if (type === 'interrupted') {
      const i2 = JSON.parse(raw) as InterruptedMsg;
      this.statusText = `检测到新的 VIS：上一张按中断处理（已解 ${i2.decodedLines} 行）`;
    } else if (type === 'error') {
      const err = JSON.parse(raw) as ErrorMsg;
      this.scanning = false;
      this.errorText = err.message;
      this.statusText = '解码失败';
    }
  }

  private clock(sec: number): string {
    const total = Math.max(0, Math.floor(sec));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  /** “解码时间”文件名：YYYYMMDD_HHmmss（时间戳为 0 时取当前时间）。 */
  private stampName(at: number): string {
    const d = new Date(at > 0 ? at : Date.now());
    const p = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  }

  /** 保存当前解码图：PNG → 系统保存器，文件名 = 解码时间。 */
  private async saveDecoded(): Promise<void> {
    if (this.pixelMap === undefined) {
      promptAction.showToast({ message: '还没有可保存的图像' });
      return;
    }
    await this.savePixelMap(this.pixelMap, `${this.stampName(this.decodeDoneAt)}.png`);
  }

  /** 保存预览中的图片（从缩略图/收藏夹打开的那张）。 */
  private async savePreviewed(): Promise<void> {
    // 与解码模块走同一套保存代码；预览图缺失时退回当前解码图
    const pm: image.PixelMap | undefined = this.previewPixel !== undefined ? this.previewPixel : this.pixelMap;
    if (pm === undefined) {
      promptAction.showToast({ message: '还没有可保存的图像' });
      return;
    }
    await this.savePixelMap(pm, `${this.stampName(this.previewShotId)}.png`);
  }

  /** 把一张 PixelMap 编码成 PNG 并写入用户选择的“下载”文件。 */
  private async savePixelMap(pm: image.PixelMap, name: string): Promise<void> {
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/png', quality: 100 });
      const ctx = getContext(this) as common.UIAbilityContext;
      const viewPicker = new picker.DocumentViewPicker(ctx);
      const opt = new picker.DocumentSaveOptions();
      // 用 DEFAULT 模式：返回的是已创建的“文件”uri，且 newFileNames 生效
      opt.newFileNames = [name];
      const uris: Array<string> = await viewPicker.save(opt);
      if (uris === null || uris.length === 0) {
        packer.release();
        promptAction.showToast({ message: '已取消保存' }); // 用户取消时给出反馈，避免“点了没反应”
        return;
      }
      let fileUri = uris[0];
      // 正常返回“文件”uri，直接写入；个别机型若返回目录 uri，则在其中创建文件（兼容）
      try {
        if (fs.statSync(fileUri).isDirectory()) {
          fileUri = `${fileUri}/${name}`;
        }
      } catch (statErr) {
        // stat 失败时按文件 uri 处理
      }
      const f = fs.openSync(fileUri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
      // 若最终仍是系统给定的文件名，再尝试按“解码时间”重命名（失败则保留原名）
      try {
        const curName = fileUri.substring(fileUri.lastIndexOf('/') + 1);
        if (curName !== name) {
          const slash = fileUri.lastIndexOf('/');
          if (slash > 0) {
            const target = `${fileUri.substring(0, slash)}/${name}`;
            fs.renameSync(fileUri, target);
            fileUri = target;
          }
        }
      } catch (renameErr) {
        // 忽略重命名失败，使用系统生成的名称
      }
      packer.release();
      const finalName = fileUri.substring(fileUri.lastIndexOf('/') + 1);
      promptAction.showToast({ message: `已保存到下载：${finalName}` });
    } catch (e) {
      const err: Error = e instanceof Error ? e : new Error(String(e));
      promptAction.showToast({ message: `保存失败：${err.message}` });
    }
  }

  /** 真正独立的深拷贝：PNG 编解码成一张全新的 PixelMap。
   *  注意：PixelMap.clone() 得到的副本会与源共享底层缓冲，源被 release 后副本会变空白。 */
  private async deepCopy(pm: image.PixelMap): Promise<image.PixelMap> {
    const packer: image.ImagePacker = image.createImagePacker();
    const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/png', quality: 100 });
    packer.release();
    const src: image.ImageSource = image.createImageSource(buf);
    const out: image.PixelMap = await src.createPixelMap();
    src.release();
    return out;
  }

  /** 把“当前显示的图”存入画廊：当前图本身不显示缩略图，只有被新图/新文件取代后才入库。 */
  private async stashCurrent(): Promise<void> {
    if (this.pixelMap === undefined) {
      return;
    }
    const shotId = this.currentShotId !== 0 ? this.currentShotId : Date.now();
    try {
      const shot: image.PixelMap = await this.deepCopy(this.pixelMap);
      const arr = this.gallery.slice();
      while (arr.length >= 5) {
        const old = arr.shift();
        if (old !== undefined) {
          old.pm.release();
        }
      }
      this.shotSeq++;
      arr.push({ imgId: shotId, key: this.shotSeq, pm: shot });
      this.gallery = arr;
    } catch (e) {
      // 克隆失败则忽略
    }
  }

  /** 展览图的沙箱目录（持久保存，应用退出后仍在）。 */
  private exhibitsDir(): string {
    return `${getContext(this).filesDir}/exhibition`;
  }

  /** 启动时加载持久化的“展览”收藏图。 */
  private async loadExhibitions(): Promise<void> {
    try {
      const dir = this.exhibitsDir();
      if (!fs.accessSync(dir)) {
        return;
      }
      const names: string[] = fs.listFileSync(dir);
      names.sort();
      const list: GalleryShot[] = [];
      for (const n of names) {
        if (!n.endsWith('.png')) {
          continue;
        }
        const imgId = Number(n.substring(0, n.length - 4));
        if (isNaN(imgId)) {
          continue;
        }
        const p = `${dir}/${n}`;
        const st = fs.statSync(p);
        const buf = new ArrayBuffer(st.size);
        const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
        fs.readSync(f.fd, buf);
        fs.closeSync(f);
        const src: image.ImageSource = image.createImageSource(buf);
        const pm: image.PixelMap = await src.createPixelMap();
        src.release();
        this.shotSeq++;
        list.push({ imgId, key: this.shotSeq, pm });
      }
      this.exhibitions = list;
      this.refreshFav();
    } catch (e) {
      // 忽略加载失败
    }
  }

  /** 该“解码图 id”是否已在“展览”中。 */
  private isFavorited(imgId: number): boolean {
    for (const e of this.exhibitions) {
      if (e.imgId === imgId) {
        return true;
      }
    }
    return false;
  }

  /** 心形状态一律以“展览”列表为准（消除竞态/错位）。 */
  private refreshFav(): void {
    this.liveFav = this.isFavorited(this.currentShotId);
    this.previewFav = this.isFavorited(this.previewShotId);
  }

  /** 收藏 / 取消收藏（按“解码图 id”去重）。带重入保护，且心形状态一律以列表为准，避免连点竞态。 */
  private async toggleFavorite(pm: image.PixelMap | undefined, imgId: number): Promise<void> {
    if (pm === undefined || imgId === 0 || this.favBusy) {
      return;
    }
    this.favBusy = true;
    try {
      // 防御：先清掉该 id 的所有既有条目（并发可能产生过重复）
      const idxs: number[] = [];
      for (let i = 0; i < this.exhibitions.length; i++) {
        if (this.exhibitions[i].imgId === imgId) {
          idxs.push(i);
        }
      }
      if (idxs.length > 0) {
        // 已收藏 → 取消：从列表移除并删除持久化文件
        const arr = this.exhibitions.slice();
        for (let k = idxs.length - 1; k >= 0; k--) {
          const removed = arr.splice(idxs[k], 1)[0];
          // 正在预览的那张不立即释放（保持预览可再点收藏回来），等关闭预览时再释放
          if (this.previewPixel === removed.pm) {
            this.deferredRelease = removed.pm;
          } else {
            removed.pm.release();
          }
        }
        this.exhibitions = arr;
        try {
          const p = `${this.exhibitsDir()}/${imgId}.png`;
          if (fs.accessSync(p)) {
            fs.unlinkSync(p);
          }
        } catch (e) {
          // 忽略删除失败
        }
      } else {
        // 未收藏 → 收藏：深拷贝一份进“展览”，并落盘 <imgId>.png
        try {
          const shot: image.PixelMap = await this.deepCopy(pm);
          const arr = this.exhibitions.slice();
          this.shotSeq++;
          arr.push({ imgId, key: this.shotSeq, pm: shot });
          this.exhibitions = arr;
          const dir = this.exhibitsDir();
          if (!fs.accessSync(dir)) {
            fs.mkdirSync(dir, true);
          }
          const packer: image.ImagePacker = image.createImagePacker();
          const buf: ArrayBuffer = await packer.packing(shot, { format: 'image/png', quality: 100 });
          packer.release();
          const f = fs.openSync(`${dir}/${imgId}.png`, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          fs.writeSync(f.fd, buf);
          fs.closeSync(f);
        } catch (e) {
          // 克隆/持久化失败则忽略
        }
      }
      // 心形状态一律以列表为准（避免竞态造成“点了没反应”）
      this.refreshFav();
    } finally {
      this.favBusy = false;
    }
  }

  private async favoriteCurrent(): Promise<void> {
    await this.toggleFavorite(this.pixelMap, this.currentShotId);
  }

  private async favoritePreview(): Promise<void> {
    await this.toggleFavorite(this.previewPixel, this.previewShotId);
  }

  /** 关闭大图预览；顺手释放“取消收藏”时暂存的那张图。 */
  private closePreview(): void {
    this.showPreview = false;
    if (this.deferredRelease !== undefined) {
      this.deferredRelease.release();
      this.deferredRelease = undefined;
    }
  }

  /** 打开大图预览（按该图 id 初始化爱心状态，避免重复收藏）。 */
  private openPreview(shot: GalleryShot): void {
    if (this.deferredRelease !== undefined) {
      this.deferredRelease.release();
      this.deferredRelease = undefined;
    }
    this.previewShotId = shot.imgId;
    this.previewPixel = shot.pm;
    this.refreshFav();
    this.showPreview = true;
  }

  private async chooseFile(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const picked: PickedFile | null = await pickWavFile(ctx);
      if (picked === null) {
        return;
      }
      this.fileName = picked.name;
      this.visLines = [];
      this.visCount = 0;
      this.processedSec = 0;
      this.decodedLines = 0;
      this.frameSeq = 0;
      this.decodeDoneAt = 0;
      this.errorText = '';
      this.modeText = '--';
      this.visCodeText = '--';
      // 切换音频：缩略图**保留**；先把“当前显示的上一张”存入画廊（它已不再是当前图）
this.previewPixel = undefined;
      this.closePreview();
      this.liveFav = false;
      this.previewFav = false;
      this.liveComplete = false;
      this.currentShotId = 0;
      this.previewShotId = 0;
      // 释放上一次会话残留的像素图（当前显示图），避免内存累积
      if (this.pixelMap !== undefined) {
        this.pixelMap.release();
        this.pixelMap = undefined;
      }
      if (this.stalePixelMap !== undefined) {
        this.stalePixelMap.release();
        this.stalePixelMap = undefined;
      }
      // 丢弃旧 Worker：保证上一次任务立即终止，且不会与本次任务串消息/串任务
      if (this.workerInstance !== null) {
        this.workerInstance.terminate();
        this.workerInstance = null;
      }
      this.statusText = '正在读取文件…';
      this.scanning = true;
      this.framePath = `${ctx.filesDir}/sstv_live.bin`;
      const w = this.ensureWorker();
      w.postMessage(JSON.stringify({
        cmd: 'scan', uri: picked.uri, coarseOffsetHz: this.offsetHz, framePath: this.framePath
      }));
      this.startSnapTimer();
    } catch (e) {
      const err: Error = e instanceof Error ? e : new Error(String(e));
      Logger.error('DecodePage', `pick failed: ${err.message}`);
      this.statusText = `选择文件失败：${err.message}`;
      this.scanning = false;
    }
  }

  private stopScan(): void {
    this.stopSnapTimer();
    // 点击“停止”即停止解码：先发 stop，再直接终止 Worker 线程，确保旧任务立刻结束（不再等它自然跑完）
    if (this.workerInstance !== null) {
      try {
        this.workerInstance.postMessage(JSON.stringify({ cmd: 'stop', uri: '', coarseOffsetHz: this.offsetHz }));
      } catch (e) {
        // 忽略：线程可能已在退出
      }
      this.workerInstance.terminate();
      this.workerInstance = null;
    }
    this.scanning = false;
    if (this.statusText.startsWith('正在') || this.statusText.startsWith('已锁')) {
      this.statusText = '已停止';
    }
  }

  /** 点击缩略图后的全屏大图预览（点任意处关闭）。 */
  @Builder
  previewBuilder() {
    Stack({ alignContent: Alignment.Center }) {
      // 背景层：全屏半透明，点击关闭（关闭处理器只挂在这里；按钮与其是并列节点，不会误触发）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#E6000000')
        .onClick((): void => {
          this.closePreview();
        })

      // 图片 + 左下=下载 / 右下=收藏（4:3，居中）
      if (this.previewPixel !== undefined) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.previewPixel)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)

          Row() {
            // 下载（保存这张图到“下载”）
            Column() {
              Image($r('app.media.ic_download'))
                .width(24)
                .height(24)
                .fillColor(Color.White)
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick((): void => {
              this.savePreviewed();
            })
            // 收藏 / 取消收藏
            Column() {
              Image(this.previewFav ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart_outline'))
                .width(24)
                .height(24)
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick((): void => {
              this.favoritePreview();
            })
          }
          .width('100%')
          .padding(12)
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('100%')
        .aspectRatio(4 / 3)
        .borderRadius(8)
        .clip(true)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Column() {
      Scroll() {
        Row() {
          Column({ space: 14 }) {
            Text('SSTV 解码')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.cc_text_title'))
              .width('100%')
            // 模式胶囊：位置/字体/颜色对齐“过境”页的「按卫星 / 按时间」
            Row({ space: 6 }) {
              Text('robot36')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.cc_on_primary'))
                .backgroundColor($r('app.color.cc_primary'))
                .borderRadius(12)
                .padding({ left: 16, right: 16, top: 5, bottom: 5 })
            }
            .width('100%')
            // —— 图像舞台（常驻框：有图显示图像，无图显示提示）——
            Column({ space: 8 }) {
              Stack({ alignContent: Alignment.BottomEnd }) {
                Column() {
                  if (this.pixelMap !== undefined) {
                    Image(this.pixelMap)
                      .width('100%')
                      .height('100%')
                      .objectFit(ImageFit.Contain)
                  } else {
                    Text(this.scanning ? '正在扫描 VIS…' : '图像将在此显示')
                      .fontSize(12)
                      .fontColor($r('app.color.cc_text_muted'))
                  }
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)

                // 爱心：仅当前图“解码完成”后才显示/可收藏
                if (this.pixelMap !== undefined && this.liveComplete) {
                  Column() {
                    Image(this.liveFav ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart_outline'))
                      .width(20)
                      .height(20)
                  }
                  .width(34)
                  .height(34)
                  .borderRadius(17)
                  .backgroundColor('#66000000')
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .margin(8)
                  .onClick((): void => {
                    this.favoriteCurrent();
                  })
                }
              }
              .width('100%')
              .aspectRatio(320 / 240)
              .backgroundColor(Color.Black)
              .borderRadius(8)
              .clip(true)

              // 保存到下载（位于图片与缩略图之间）
              Button('保存到下载')
                .type(ButtonType.Capsule)
                .width('86%')
                .height(40)
                .backgroundColor($r('app.color.cc_primary'))
                .fontColor($r('app.color.cc_on_primary'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .enabled(this.pixelMap !== undefined)
                .opacity(this.pixelMap !== undefined ? 1 : 0.4)
                .onClick((): void => {
                  this.saveDecoded();
                })

              // 已解码图片缩略图：最多 5 张、每行最多 4 个（右端留一个空位）、左对齐、可点开大图
              if (this.gallery.length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.gallery, (shot: GalleryShot, idx: number): void => {
                    Image(shot.pm)
                      .width('19%')
                      .aspectRatio(4 / 3)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(6)
                      .margin({ right: 6, bottom: 6 })
                      .onClick((): void => {
                        this.openPreview(shot);
                      })
                  }, (shot: GalleryShot): string => `${shot.key}`)
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.cc_card'))
            .borderRadius(12)
            .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })

            // —— 进度条 ——
            Column({ space: 8 }) {
              Progress({
                value: this.durationSec > 0 ? this.processedSec : 0,
                total: this.durationSec > 0 ? this.durationSec : 1
              })
                .width('100%')
                .color($r('app.color.cc_primary'))
                .style({ strokeWidth: 6 })
              // 音频时间与进度（进度条下方）
              Text(`已处理 ${this.clock(this.processedSec)} / ${this.durationSec > 0 ? this.clock(this.durationSec) : '--'}`)
                .fontSize(12)
                .fontColor($r('app.color.cc_text_muted'))
                .width('100%')
              // 选择 / 停止
              Row({ space: 12 }) {
                Button(this.scanning ? '扫描中…' : '选择音频文件（WAV）')
                  .type(ButtonType.Normal)
                  .layoutWeight(2)
                  .height(40)
                  .borderRadius(8)
                  .backgroundColor($r('app.color.cc_primary'))
                  .fontColor($r('app.color.cc_on_primary'))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .enabled(!this.scanning)
                  .onClick((): void => {
                    this.chooseFile();
                  })
                Button('停止')
                  .type(ButtonType.Normal)
                  .layoutWeight(1)
                  .height(40)
                  .borderRadius(8)
                  .backgroundColor($r('app.color.cc_card'))
                  .fontColor(this.scanning ? $r('app.color.cc_text_body') : $r('app.color.cc_text_muted'))
                  .fontSize(14)
                  .border({ width: 1, color: $r('app.color.cc_border'), radius: 8 })
                  .enabled(this.scanning)
                  .onClick((): void => {
                    this.stopScan();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.cc_card'))
            .borderRadius(12)
            .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })

            // —— 展览：点亮爱心的图片（双列，可点击放大） ——
            Column({ space: 8 }) {
              Text('展览')
                .fontSize(12)
                .fontColor($r('app.color.cc_text_title'))
                .width('100%')
              if (this.exhibitions.length === 0) {
                Text('点亮图片右下角的爱心，收藏到这里')
                  .fontSize(12)
                  .fontColor($r('app.color.cc_text_muted'))
                  .width('100%')
              } else {
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                  ForEach(this.exhibitions, (shot: GalleryShot, idx: number): void => {
                    Image(shot.pm)
                      .width('48%')
                      .aspectRatio(4 / 3)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(6)
                      .margin({ bottom: 8 })
                      .onClick((): void => {
                        this.openPreview(shot);
                      })
                  }, (shot: GalleryShot): string => `ex-${shot.key}`)
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.cc_card'))
            .borderRadius(12)
            .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
          }
          .width('100%')
          .constraintSize({ maxWidth: 720 })
          .padding({ left: 16, right: 16, top: 16, bottom: this.barClearance })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.color_bg'))

      // 预览覆盖层：页内绘制（bindContentCover 会在页面重渲染时被收起，导致“取消收藏就退出”）
      if (this.showPreview) {
        this.previewBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.color_bg'))
  }
}