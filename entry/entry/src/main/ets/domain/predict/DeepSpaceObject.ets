/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import {
  CK2, CK4, EARTH_RADIUS, J3_HARMONIC, TWO_THIRDS, XKE, TWO_PI, PI
} from './Constants';
import { SatOrbitalData } from './OrbitalData';
import { SatOrbitalObject } from './OrbitalObject';
import { mod2PI } from '../../common/utils/MathUtils';

export class SatDeepSpaceValueObject {
  eosq = 0.0;
  sinio = 0.0;
  cosio = 0.0;
  betao = 0.0;
  aodp = 0.0;
  theta2 = 0.0;
  sing = 0.0;
  cosg = 0.0;
  betao2 = 0.0;
  xmdot = 0.0;
  omgdot = 0.0;
  xnodot = 0.0;
  xnodp = 0.0;
  xll = 0.0;
  omgadf = 0.0;
  xnode = 0.0;
  em = 0.0;
  xinc = 0.0;
  xn = 0.0;
  t = 0.0;
  ds50 = 0.0;
}

export class SatDeepSpaceObject extends SatOrbitalObject {
  private readonly c1: number;
  private readonly c4: number;
  private readonly x1mth2: number;
  private readonly x3thm1: number;
  private readonly xlcof: number;
  private readonly xnodcf: number;
  private readonly t2cof: number;
  private readonly aycof: number;
  private readonly x7thm1: number;
  private readonly deep: SatDeepSpaceCalculator;
  private readonly dsv: SatDeepSpaceValueObject = new SatDeepSpaceValueObject();

  constructor(data: SatOrbitalData) {
    super(data);
    const a1 = Math.pow(XKE / data.xno, TWO_THIRDS);
    this.dsv.cosio = Math.cos(data.xincl);
    this.dsv.theta2 = this.dsv.cosio * this.dsv.cosio;
    this.x3thm1 = 3.0 * this.dsv.theta2 - 1;
    this.dsv.eosq = data.eccn * data.eccn;
    this.dsv.betao2 = 1.0 - this.dsv.eosq;
    this.dsv.betao = Math.sqrt(this.dsv.betao2);
    const del1 = 1.5 * CK2 * this.x3thm1 / (a1 * a1 * this.dsv.betao * this.dsv.betao2);
    const ao = a1 * (1.0 - del1 * (0.5 * TWO_THIRDS + del1 * (1.0 + 134.0 / 81.0 * del1)));
    const delo = 1.5 * CK2 * this.x3thm1 / (ao * ao * this.dsv.betao * this.dsv.betao2);
    this.dsv.xnodp = data.xno / (1.0 + delo);
    this.dsv.aodp = ao / (1.0 - delo);
    this.setPerigee((this.dsv.aodp * (1.0 - data.eccn) - 1.0) * EARTH_RADIUS);
    const pinvsq = this.invert(this.dsv.aodp * this.dsv.aodp * this.dsv.betao2 * this.dsv.betao2);
    this.dsv.sing = Math.sin(data.omegao);
    this.dsv.cosg = Math.cos(data.omegao);
    const tsi = this.invert(this.dsv.aodp - this.s4);
    const eta = this.dsv.aodp * data.eccn * tsi;
    const etasq = eta * eta;
    const eeta = data.eccn * eta;
    const psisq = Math.abs(1.0 - etasq);
    const coef = this.qoms24 * Math.pow(tsi, 4.0);
    const coef1 = coef / Math.pow(psisq, 3.5);
    const c2 = coef1 * this.dsv.xnodp * (this.dsv.aodp * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
      + 0.75 * CK2 * tsi / psisq * this.x3thm1 * (8.0 + 3.0 * etasq * (8.0 + etasq)));
    this.c1 = data.bstar * c2;
    this.dsv.sinio = Math.sin(data.xincl);
    const a3ovk2 = -J3_HARMONIC / CK2;
    this.x1mth2 = 1.0 - this.dsv.theta2;
    this.c4 =
      2 * this.dsv.xnodp * coef1 * this.dsv.aodp * this.dsv.betao2 * (eta * (2.0 + 0.5 * etasq) +
        data.eccn * (0.5 + 2 * etasq) - 2 * CK2 * tsi / (this.dsv.aodp * psisq) * (-3 * this.x3thm1 *
        (1.0 - 2 * eeta + etasq * (1.5 - 0.5 * eeta)) + (0.75 * this.x1mth2 * (2.0 * etasq - eeta *
        (1.0 + etasq)) * Math.cos(2.0 * data.omegao))));
    const theta4 = this.dsv.theta2 * this.dsv.theta2;
    const temp1 = 3.0 * CK2 * pinvsq * this.dsv.xnodp;
    const temp2 = temp1 * CK2 * pinvsq;
    const temp3 = 1.25 * CK4 * pinvsq * pinvsq * this.dsv.xnodp;
    this.dsv.xmdot =
      this.dsv.xnodp + 0.5 * temp1 * this.dsv.betao * this.x3thm1 + 0.0625 * temp2 * this.dsv.betao *
      (13 - 78 * this.dsv.theta2 + 137 * theta4);
    const x1m5th = 1.0 - 5 * this.dsv.theta2;
    this.dsv.omgdot =
      -0.5 * temp1 * x1m5th + 0.0625 * temp2 * (7.0 - 114 * this.dsv.theta2 + 395 * theta4) +
      temp3 * (3.0 - 36 * this.dsv.theta2 + 49 * theta4);
    const xhdot1 = -temp1 * this.dsv.cosio;
    this.dsv.xnodot =
      xhdot1 + (0.5 * temp2 * (4.0 - 19 * this.dsv.theta2) + 2 * temp3 * (3.0 - 7 * this.dsv.theta2)) *
      this.dsv.cosio;
    this.xnodcf = 3.5 * this.dsv.betao2 * xhdot1 * this.c1;
    this.t2cof = 1.5 * this.c1;
    this.xlcof = 0.125 * a3ovk2 * this.dsv.sinio * (3.0 + 5 * this.dsv.cosio) / (1.0 + this.dsv.cosio);
    this.aycof = 0.25 * a3ovk2 * this.dsv.sinio;
    this.x7thm1 = 7.0 * this.dsv.theta2 - 1;
    this.deep = new SatDeepSpaceCalculator(data, this.dsv);
  }

  protected propagate(tSince: number): void {
    this.calculateSDP4(tSince);
  }

  calculateSDP4(tSince: number): void {
    const temp = new Array<number>(12);
    const xmdf = this.data.xmo + this.dsv.xmdot * tSince;
    const tsq = tSince * tSince;
    const templ = this.t2cof * tsq;
    this.dsv.xll = xmdf + this.dsv.xnodp * templ;
    this.dsv.omgadf = this.data.omegao + this.dsv.omgdot * tSince;
    const xnoddf = this.data.xnodeo + this.dsv.xnodot * tSince;
    this.dsv.xnode = xnoddf + this.xnodcf * tsq;
    const tempa = 1.0 - this.c1 * tSince;
    const tempe = this.data.bstar * this.c4 * tSince;
    this.dsv.xn = this.dsv.xnodp;
    this.dsv.t = tSince;
    this.deep.dpsec(this.data);
    const a = Math.pow(XKE / this.dsv.xn, TWO_THIRDS) * tempa * tempa;
    this.dsv.em -= tempe;
    this.deep.dpper();
    const xl = this.dsv.xll + this.dsv.omgadf + this.dsv.xnode;
    const beta = Math.sqrt(1.0 - this.dsv.em * this.dsv.em);
    this.dsv.xn = XKE / Math.pow(a, 1.5);
    const axn = this.dsv.em * Math.cos(this.dsv.omgadf);
    temp[0] = this.invert(a * beta * beta);
    const xll = temp[0] * this.xlcof * axn;
    const aynl = temp[0] * this.aycof;
    const xlt = xl + xll;
    const ayn = this.dsv.em * Math.sin(this.dsv.omgadf) + aynl;
    const capu = mod2PI(xlt - this.dsv.xnode);
    temp[2] = capu;
    this.converge(temp, axn, ayn, capu);
    this.deepSpacePosVel(temp, a, axn, ayn);
    this.calculatePhase(xlt, this.dsv.xnode, this.dsv.omgadf);
  }

  private deepSpacePosVel(temp: number[], a: number, axn: number, ayn: number): void {
    const ecose = temp[5] + temp[6];
    const esine = temp[3] - temp[4];
    const elsq = axn * axn + ayn * ayn;
    temp[0] = 1.0 - elsq;
    const pl = a * temp[0];
    temp[9] = a * (1.0 - ecose);
    temp[1] = this.invert(temp[9]);
    temp[10] = XKE * Math.sqrt(a) * esine * temp[1];
    temp[11] = XKE * Math.sqrt(pl) * temp[1];
    temp[2] = a * temp[1];
    const betal = Math.sqrt(temp[0]);
    temp[3] = this.invert(1.0 + betal);
    const cosu = temp[2] * (temp[8] - axn + ayn * esine * temp[3]);
    const sinu = temp[2] * (temp[7] - ayn - axn * esine * temp[3]);
    const u = Math.atan2(sinu, cosu);
    const sin2u = 2.0 * sinu * cosu;
    const cos2u = 2.0 * cosu * cosu - 1;
    temp[0] = this.invert(pl);
    temp[1] = CK2 * temp[0];
    temp[2] = temp[1] * temp[0];
    const rk = temp[9] * (1.0 - 1.5 * temp[2] * betal * this.x3thm1) + 0.5 * temp[1] * this.x1mth2 * cos2u;
    const uk = u - 0.25 * temp[2] * this.x7thm1 * sin2u;
    const xnodek = this.dsv.xnode + 1.5 * temp[2] * this.dsv.cosio * sin2u;
    const xinck = this.dsv.xinc + 1.5 * temp[2] * this.dsv.cosio * this.dsv.sinio * cos2u;
    const rdotk = temp[10] - this.dsv.xn * temp[1] * this.x1mth2 * sin2u;
    const rfdotk = temp[11] + this.dsv.xn * temp[1] * (this.x1mth2 * cos2u + 1.5 * this.x3thm1);
    super.calculatePosAndVel(rk, uk, xnodek, xinck, rdotk, rfdotk);
  }
}

export class SatDeepSpaceCalculator {
  private readonly zSinis = 3.9785416E-1;
  private readonly zSings = -9.8088458E-1;
  private readonly zNs = 1.19459E-5;
  private readonly c1ss = 2.9864797E-6;
  private readonly zEs = 1.675E-2;
  private readonly zNl = 1.5835218E-4;
  private readonly c1l = 4.7968065E-7;
  private readonly zEl = 5.490E-2;
  private readonly root22 = 1.7891679E-6;
  private readonly root32 = 3.7393792E-7;
  private readonly root44 = 7.3636953E-9;
  private readonly root52 = 1.1428639E-7;
  private readonly root54 = 2.1765803E-9;
  private readonly tHdt = 4.3752691E-3;
  private readonly q22 = 1.7891679E-6;
  private readonly q31 = 2.1460748E-6;
  private readonly q33 = 2.2123015E-7;
  private readonly g22 = 5.7686396;
  private readonly g32 = 9.5240898E-1;
  private readonly g44 = 1.8014998;
  private readonly g52 = 1.0508330;
  private readonly g54 = 4.4108898;

  private readonly data: SatOrbitalData;
  private readonly dsv: SatDeepSpaceValueObject;

  private thgr: number = 0;
  private xnq: number = 0;
  private xqncl: number = 0;
  private omegaq: number = 0;
  private zmol = 0.0;
  private zmos = 0.0;
  private savtsn = 0.0;
  private ee2 = 0.0;
  private e3 = 0.0;
  private xi2 = 0.0;
  private xl2 = 0.0;
  private xl3 = 0.0;
  private xl4 = 0.0;
  private xgh2 = 0.0;
  private xgh3 = 0.0;
  private xgh4 = 0.0;
  private xh2 = 0.0;
  private xh3 = 0.0;
  private sse = 0.0;
  private ssi = 0.0;
  private ssg = 0.0;
  private xi3 = 0.0;
  private se2 = 0.0;
  private si2 = 0.0;
  private sl2 = 0.0;
  private sgh2 = 0.0;
  private sh2 = 0.0;
  private se3 = 0.0;
  private si3 = 0.0;
  private sl3 = 0.0;
  private sgh3 = 0.0;
  private sh3 = 0.0;
  private sl4 = 0.0;
  private sgh4 = 0.0;
  private ssl = 0.0;
  private ssh = 0.0;
  private d3210 = 0.0;
  private d3222 = 0.0;
  private d4410 = 0.0;
  private d4422 = 0.0;
  private d5220 = 0.0;
  private d5232 = 0.0;
  private d5421 = 0.0;
  private d5433 = 0.0;
  private del1 = 0.0;
  private del2 = 0.0;
  private del3 = 0.0;
  private fasx2 = 0.0;
  private fasx4 = 0.0;
  private fasx6 = 0.0;
  private xlamo = 0.0;
  private xfact = 0.0;
  private xni: number = 0;
  private atime: number = 0;
  private readonly stepp = 720.0;
  private readonly stepn = -720.0;
  private readonly step2 = 259200.0;
  private preep = 0.0;
  private pl = 0.0;
  private sghs = 0.0;
  private xli: number = 0;
  private d2201 = 0.0;
  private d2211 = 0.0;
  private sghl = 0.0;
  private sh1 = 0.0;
  private pinc = 0.0;
  private pe = 0.0;
  private shs = 0.0;
  private zsingl = 0.0;
  private zcosgl = 0.0;
  private zsinhl = 0.0;
  private zcoshl = 0.0;
  private zsinil = 0.0;
  private zcosil = 0.0;
  private a1v = 0.0;
  private a2v = 0.0;
  private a3v = 0.0;
  private a4v = 0.0;
  private a5v = 0.0;
  private a6v = 0.0;
  private a7v = 0.0;
  private a8v = 0.0;
  private a9v = 0.0;
  private a10v = 0.0;
  private ainv2 = 0.0;
  private alfdp = 0.0;
  private aqnv = 0.0;
  private sgh = 0.0;
  private sini2 = 0.0;
  private sinis = 0.0;
  private sinok = 0.0;
  private sh = 0.0;
  private si = 0.0;
  private sil = 0.0;
  private day = 0.0;
  private betdp = 0.0;
  private dalf = 0.0;
  private bfact = 0.0;
  private c = 0.0;
  private cc = 0.0;
  private cosis = 0.0;
  private cosok = 0.0;
  private cosq = 0.0;
  private ctem = 0.0;
  private f322 = 0.0;
  private zx = 0.0;
  private zy = 0.0;
  private dbet = 0.0;
  private dls = 0.0;
  private eoc = 0.0;
  private eq = 0.0;
  private f2 = 0.0;
  private f220 = 0.0;
  private f221 = 0.0;
  private f3 = 0.0;
  private f311 = 0.0;
  private f321 = 0.0;
  private xnoh = 0.0;
  private f330 = 0.0;
  private f441 = 0.0;
  private f442 = 0.0;
  private f522 = 0.0;
  private f523 = 0.0;
  private f542 = 0.0;
  private f543 = 0.0;
  private g200 = 0.0;
  private g201 = 0.0;
  private g211 = 0.0;
  private pgh = 0.0;
  private ph = 0.0;
  private s1 = 0.0;
  private s2 = 0.0;
  private s3 = 0.0;
  private s4num = 0.0;
  private s5 = 0.0;
  private s6 = 0.0;
  private s7 = 0.0;
  private se = 0.0;
  private sel = 0.0;
  private ses = 0.0;
  private xls = 0.0;
  private g300 = 0.0;
  private g310 = 0.0;
  private g322 = 0.0;
  private g410 = 0.0;
  private g422 = 0.0;
  private g520 = 0.0;
  private g521 = 0.0;
  private g532 = 0.0;
  private g533 = 0.0;
  private gam = 0.0;
  private sinq = 0.0;
  private sinzf = 0.0;
  private sis = 0.0;
  private sl = 0.0;
  private sll = 0.0;
  private sls = 0.0;
  private stem = 0.0;
  private temp = 0.0;
  private temp1 = 0.0;
  private x1v = 0.0;
  private x2v = 0.0;
  private x2li = 0.0;
  private x2omi = 0.0;
  private x3v = 0.0;
  private x4v = 0.0;
  private x5v = 0.0;
  private x6v = 0.0;
  private x7v = 0.0;
  private x8v = 0.0;
  private xl = 0.0;
  private xldot = 0.0;
  private xmao = 0.0;
  private xnddt = 0.0;
  private xndot = 0.0;
  private xno2 = 0.0;
  private xnodce = 0.0;
  private xnoi = 0.0;
  private xomi = 0.0;
  private xpidot = 0.0;
  private z1 = 0.0;
  private z11 = 0.0;
  private z12 = 0.0;
  private z13 = 0.0;
  private z2 = 0.0;
  private z21 = 0.0;
  private z22 = 0.0;
  private z23 = 0.0;
  private z3 = 0.0;
  private z31 = 0.0;
  private z32 = 0.0;
  private z33 = 0.0;
  private ze = 0.0;
  private zf = 0.0;
  private zm = 0.0;
  private zn = 0.0;
  private zsing = 0.0;
  private zsinh = 0.0;
  private zsini = 0.0;
  private zcosg = 0.0;
  private zcosh = 0.0;
  private zcosi = 0.0;
  private delt = 0.0;
  private ft = 0.0;
  private resonance = false;
  private synchronous = false;
  private doLoop = false;
  private epochRestart = false;

  constructor(data: SatOrbitalData, dsv: SatDeepSpaceValueObject) {
    this.data = data;
    this.dsv = dsv;
    this.thgr = this.thetaG(data.epoch);
    let localEq = data.eccn;
    this.eq = localEq;
    this.xnq = dsv.xnodp;
    this.aqnv = 1.0 / dsv.aodp;
    this.xqncl = data.xincl;
    this.xmao = data.xmo;
    this.xpidot = dsv.omgdot + dsv.xnodot;
    this.sinq = Math.sin(data.xnodeo);
    this.cosq = Math.cos(data.xnodeo);
    this.omegaq = data.omegao;
    this.day = this.dsv.ds50 + 18261.5;
    if (Math.abs(this.day - this.preep) > 1.0E-6) {
      this.preep = this.day;
      this.xnodce = 4.5236020 - 9.2422029E-4 * this.day;
      this.stem = Math.sin(this.xnodce);
      this.ctem = Math.cos(this.xnodce);
      this.zcosil = 0.91375164 - 0.03568096 * this.ctem;
      this.zsinil = Math.sqrt(1.0 - this.zcosil * this.zcosil);
      this.zsinhl = 0.089683511 * this.stem / this.zsinil;
      this.zcoshl = Math.sqrt(1.0 - this.zsinhl * this.zsinhl);
      this.c = 4.7199672 + 0.22997150 * this.day;
      this.gam = 5.8351514 + 0.0019443680 * this.day;
      this.zmol = mod2PI(this.c - this.gam);
      this.zx = 0.39785416 * this.stem / this.zsinil;
      this.zy = this.zcoshl * this.ctem + 0.91744867 * this.zsinhl * this.stem;
      this.zx = Math.atan2(this.zx, this.zy);
      this.zx = this.gam + this.zx - this.xnodce;
      this.zcosgl = Math.cos(this.zx);
      this.zsingl = Math.sin(this.zx);
      this.zmos = mod2PI(6.2565837 + 0.017201977 * this.day);
    } else {
      this.zmol = 0.0;
      this.zmos = 0.0;
    }
    this.doSolarTerms();

    localEq = this.eq;
    let localEosq = dsv.eosq;
    let localSinio = dsv.sinio;
    let localCosio = dsv.cosio;
    let localTheta2 = dsv.theta2;
    this.resonance = false;
    this.synchronous = false;
    if (!(this.xnq < 0.0052359877 && this.xnq > 0.0034906585)) {
      if (this.xnq < 0.00826 || this.xnq > 0.00924) {
        if (localEq < 0.5) {
          this.resonance = true;
        }
      }
      this.eoc = localEq * localEosq;
      this.g201 = -0.306 - (localEq - 0.64) * 0.440;
      if (localEq <= 0.65) {
        this.g211 = 3.616 - 13.247 * localEq + 16.290 * localEosq;
        this.g310 = -19.302 + 117.390 * localEq - 228.419 * localEosq + 156.591 * this.eoc;
        this.g322 = -18.9068 + 109.7927 * localEq - 214.6334 * localEosq + 146.5816 * this.eoc;
        this.g410 = -41.122 + 242.694 * localEq - 471.094 * localEosq + 313.953 * this.eoc;
        this.g422 = -146.407 + 841.880 * localEq - 1629.014 * localEosq + 1083.435 * this.eoc;
        this.g520 = -532.114 + 3017.977 * localEq - 5740 * localEosq + 3708.276 * this.eoc;
      } else {
        this.g211 = -72.099 + 331.819 * localEq - 508.738 * localEosq + 266.724 * this.eoc;
        this.g310 = -346.844 + 1582.851 * localEq - 2415.925 * localEosq + 1246.113 * this.eoc;
        this.g322 = -342.585 + 1554.908 * localEq - 2366.899 * localEosq + 1215.972 * this.eoc;
        this.g410 = -1052.797 + 4758.686 * localEq - 7193.992 * localEosq + 3651.957 * this.eoc;
        this.g422 = -3581.69 + 16178.11 * localEq - 24462.77 * localEosq + 12422.52 * this.eoc;
        if (localEq <= 0.715) {
          this.g520 = 1464.74 - 4664.75 * localEq + 3763.64 * localEosq;
        } else {
          this.g520 = -5149.66 + 29936.92 * localEq - 54087.36 * localEosq + 31324.56 * this.eoc;
        }
      }
      if (localEq < 0.7) {
        this.g533 = -919.2277 + 4988.61 * localEq - 9064.77 * localEosq + 5542.21 * this.eoc;
        this.g521 = -822.71072 + 4568.6173 * localEq - 8491.4146 * localEosq + 5337.524 * this.eoc;
        this.g532 = -853.666 + 4690.25 * localEq - 8624.77 * localEosq + 5341.4 * this.eoc;
      } else {
        this.g533 = -37995.78 + 161616.52 * localEq - 229838.2 * localEosq + 109377.94 * this.eoc;
        this.g521 = -51752.104 + 218913.95 * localEq - 309468.16 * localEosq + 146349.42 * this.eoc;
        this.g532 = -40023.88 + 170470.89 * localEq - 242699.48 * localEosq + 115605.82 * this.eoc;
      }
      this.sini2 = localSinio * localSinio;
      this.f220 = 0.75 * (1.0 + 2 * localCosio + localTheta2);
      this.f221 = 1.5 * this.sini2;
      this.f321 = 1.875 * localSinio * (1.0 - 2 * localCosio - 3.0 * localTheta2);
      this.f322 = -1.875 * localSinio * (1.0 + 2 * localCosio - 3.0 * localTheta2);
      this.f441 = 35 * this.sini2 * this.f220;
      this.f442 = 39.3750 * this.sini2 * this.sini2;
      this.f522 =
        9.84375 * localSinio * (this.sini2 * (1.0 - 2 * localCosio - 5 * localTheta2) + 0.33333333 *
        (-2 + 4 * localCosio + 6 * localTheta2));
      this.f523 =
        localSinio * (4.92187512 * this.sini2 * (-2 - 4 * localCosio + 10 * localTheta2) +
        6.56250012 * (1.0 + 2 * localCosio - 3.0 * localTheta2));
      this.f542 =
        29.53125 * localSinio * (2.0 - 8 * localCosio + localTheta2 * (-12 + 8 * localCosio + 10 * localTheta2));
      this.f543 =
        29.53125 * localSinio * (-2 - 8 * localCosio + localTheta2 * (12 + 8 * localCosio - 10 * localTheta2));
      this.xno2 = this.xnq * this.xnq;
      this.ainv2 = this.aqnv * this.aqnv;
      this.temp1 = 3.0 * this.xno2 * this.ainv2;
      this.temp = this.temp1 * this.root22;
      this.d2201 = this.temp * this.f220 * this.g201;
      this.d2211 = this.temp * this.f221 * this.g211;
      this.temp1 *= this.aqnv;
      this.temp = this.temp1 * this.root32;
      this.d3210 = this.temp * this.f321 * this.g310;
      this.d3222 = this.temp * this.f322 * this.g322;
      this.temp1 *= this.aqnv;
      this.temp = 2.0 * this.temp1 * this.root44;
      this.d4410 = this.temp * this.f441 * this.g410;
      this.d4422 = this.temp * this.f442 * this.g422;
      this.temp1 *= this.aqnv;
      this.temp = this.temp1 * this.root52;
      this.d5220 = this.temp * this.f522 * this.g520;
      this.d5232 = this.temp * this.f523 * this.g532;
      this.temp = 2.0 * this.temp1 * this.root54;
      this.d5421 = this.temp * this.f542 * this.g521;
      this.d5433 = this.temp * this.f543 * this.g533;
      this.xlamo = this.xmao + data.xnodeo + data.xnodeo - this.thgr - this.thgr;
      this.bfact = dsv.xmdot + dsv.xnodot + dsv.xnodot - this.tHdt - this.tHdt;
      this.bfact += this.ssl + this.ssh + this.ssh;
    } else {
      this.resonance = true;
      this.synchronous = true;
      this.g200 = 1.0 + localEosq * (-2.5 + 0.8125 * localEosq);
      this.g310 = 1.0 + 2 * localEosq;
      this.g300 = 1.0 + localEosq * (-6 + 6.60937 * localEosq);
      this.f220 = 0.75 * (1.0 + localCosio) * (1.0 + localCosio);
      this.f311 =
        0.9375 * localSinio * localSinio * (1.0 + 3.0 * localCosio) - 0.75 * (1.0 + localCosio);
      this.f330 = 1.0 + localCosio;
      this.f330 *= 1.875 * this.f330 * this.f330;
      this.del1 = 3.0 * this.xnq * this.xnq * this.aqnv * this.aqnv;
      this.del2 = 2.0 * this.del1 * this.f220 * this.g200 * this.q22;
      this.del3 = 3.0 * this.del1 * this.f330 * this.g300 * this.q33 * this.aqnv;
      this.del1 *= this.f311 * this.g310 * this.q31 * this.aqnv;
      this.fasx2 = 0.13130908;
      this.fasx4 = 2.8843198;
      this.fasx6 = 0.37448087;
      this.xlamo = this.xmao + data.xnodeo + data.omegao - this.thgr;
      this.bfact = dsv.xmdot + this.xpidot - this.tHdt;
      this.bfact += this.ssl + this.ssg + this.ssh;
    }
    this.xfact = this.bfact - this.xnq;
    this.xli = this.xlamo;
    this.xni = this.xnq;
    this.atime = 0.0;
  }

  dpper(): void {
    this.sinis = Math.sin(this.dsv.xinc);
    this.cosis = Math.cos(this.dsv.xinc);
    if (Math.abs(this.savtsn - this.dsv.t) >= 30) {
      this.savtsn = this.dsv.t;
      this.zm = this.zmos + this.zNs * this.dsv.t;
      this.zf = this.zm + 2 * this.zEs * Math.sin(this.zm);
      this.sinzf = Math.sin(this.zf);
      this.f2 = 0.5 * this.sinzf * this.sinzf - 0.25;
      this.f3 = -0.5 * this.sinzf * Math.cos(this.zf);
      this.ses = this.se2 * this.f2 + this.se3 * this.f3;
      this.sis = this.si2 * this.f2 + this.si3 * this.f3;
      this.sls = this.sl2 * this.f2 + this.sl3 * this.f3 + this.sl4 * this.sinzf;
      this.sghs = this.sgh2 * this.f2 + this.sgh3 * this.f3 + this.sgh4 * this.sinzf;
      this.shs = this.sh2 * this.f2 + this.sh3 * this.f3;
      this.zm = this.zmol + this.zNl * this.dsv.t;
      this.zf = this.zm + 2 * this.zEl * Math.sin(this.zm);
      this.sinzf = Math.sin(this.zf);
      this.f2 = 0.5 * this.sinzf * this.sinzf - 0.25;
      this.f3 = -0.5 * this.sinzf * Math.cos(this.zf);
      this.sel = this.ee2 * this.f2 + this.e3 * this.f3;
      this.sil = this.xi2 * this.f2 + this.xi3 * this.f3;
      this.sll = this.xl2 * this.f2 + this.xl3 * this.f3 + this.xl4 * this.sinzf;
      this.sghl = this.xgh2 * this.f2 + this.xgh3 * this.f3 + this.xgh4 * this.sinzf;
      this.sh1 = this.xh2 * this.f2 + this.xh3 * this.f3;
      this.pe = this.ses + this.sel;
      this.pinc = this.sis + this.sil;
      this.pl = this.sls + this.sll;
    }
    this.pgh = this.sghs + this.sghl;
    this.ph = this.shs + this.sh1;
    this.dsv.xinc += this.pinc;
    this.dsv.em += this.pe;
    if (this.xqncl >= 0.2) {
      this.ph /= this.dsv.sinio;
      this.pgh -= this.dsv.cosio * this.ph;
      this.dsv.omgadf += this.pgh;
      this.dsv.xnode += this.ph;
      this.dsv.xll += this.pl;
    } else {
      this.applyPeriodics();
      if (Math.abs(this.xnoh - this.dsv.xnode) > PI) {
        if (this.dsv.xnode < this.xnoh) {
          this.dsv.xnode += TWO_PI;
        } else {
          this.dsv.xnode -= TWO_PI;
        }
      }
      this.dsv.xll += this.pl;
      this.dsv.omgadf = this.xls - this.dsv.xll - Math.cos(this.dsv.xinc) * this.dsv.xnode;
    }
  }

  dpsec(params: SatOrbitalData): void {
    this.dsv.xll += this.ssl * this.dsv.t;
    this.dsv.omgadf += this.ssg * this.dsv.t;
    this.dsv.xnode += this.ssh * this.dsv.t;
    this.dsv.em = params.eccn + this.sse * this.dsv.t;
    this.dsv.xinc = params.xincl + this.ssi * this.dsv.t;
    if (this.dsv.xinc < 0) {
      this.dsv.xinc = -this.dsv.xinc;
      this.dsv.xnode += PI;
      this.dsv.omgadf -= PI;
    }
    if (!this.resonance) {
      return;
    }
    do {
      this.processEpochRestartLoop();
    } while (this.doLoop && this.epochRestart);
    this.dsv.xn = this.xni + this.xndot * this.ft + this.xnddt * this.ft * this.ft * 0.5;
    this.xl = this.xli + this.xldot * this.ft + this.xndot * this.ft * this.ft * 0.5;
    this.temp = -this.dsv.xnode + this.thgr + this.dsv.t * this.tHdt;
    if (this.synchronous) {
      this.dsv.xll = this.xl - this.dsv.omgadf + this.temp;
    } else {
      this.dsv.xll = this.xl + this.temp + this.temp;
    }
  }

  private doSolarTerms(): void {
    this.savtsn = 1E20;
    this.zcosg = 1.945905E-1;
    this.zsing = this.zSings;
    this.zcosi = 9.1744867E-1;
    this.zsini = this.zSinis;
    this.zcosh = this.cosq;
    this.zsinh = this.sinq;
    this.cc = this.c1ss;
    this.zn = this.zNs;
    this.ze = this.zEs;
    this.xnoi = 1.0 / this.xnq;
    this.calculateSolarTerms();
    this.calculateLunarTerms();
    this.calculateSolarTerms();
    this.sse += this.se;
    this.ssi += this.si;
    this.ssl += this.sl;
    this.ssg = this.ssg + this.sgh - this.dsv.cosio / this.dsv.sinio * this.sh;
    this.ssh += this.sh / this.dsv.sinio;
  }

  private calculateLunarTerms(): void {
    this.sse = this.se;
    this.ssi = this.si;
    this.ssl = this.sl;
    this.ssh = this.sh / this.dsv.sinio;
    this.ssg = this.sgh - this.dsv.cosio * this.ssh;
    this.se2 = this.ee2;
    this.si2 = this.xi2;
    this.sl2 = this.xl2;
    this.sgh2 = this.xgh2;
    this.sh2 = this.xh2;
    this.se3 = this.e3;
    this.si3 = this.xi3;
    this.sl3 = this.xl3;
    this.sgh3 = this.xgh3;
    this.sh3 = this.xh3;
    this.sl4 = this.xl4;
    this.sgh4 = this.xgh4;
    this.zcosg = this.zcosgl;
    this.zsing = this.zsingl;
    this.zcosi = this.zcosil;
    this.zsini = this.zsinil;
    this.zcosh = this.zcoshl * this.cosq + this.zsinhl * this.sinq;
    this.zsinh = this.sinq * this.zcoshl - this.cosq * this.zsinhl;
    this.zn = this.zNl;
    this.cc = this.c1l;
    this.ze = this.zEl;
  }

  private calculateSolarTerms(): void {
    this.a1v = this.zcosg * this.zcosh + this.zsing * this.zcosi * this.zsinh;
    this.a3v = -this.zsing * this.zcosh + this.zcosg * this.zcosi * this.zsinh;
    this.a7v = -this.zcosg * this.zsinh + this.zsing * this.zcosi * this.zcosh;
    this.a8v = this.zsing * this.zsini;
    this.a9v = this.zsing * this.zsinh + this.zcosg * this.zcosi * this.zcosh;
    this.a10v = this.zcosg * this.zsini;
    this.a2v = this.dsv.cosio * this.a7v + this.dsv.sinio * this.a8v;
    this.a4v = this.dsv.cosio * this.a9v + this.dsv.sinio * this.a10v;
    this.a5v = -this.dsv.sinio * this.a7v + this.dsv.cosio * this.a8v;
    this.a6v = -this.dsv.sinio * this.a9v + this.dsv.cosio * this.a10v;
    this.x1v = this.a1v * this.dsv.cosg + this.a2v * this.dsv.sing;
    this.x2v = this.a3v * this.dsv.cosg + this.a4v * this.dsv.sing;
    this.x3v = -this.a1v * this.dsv.sing + this.a2v * this.dsv.cosg;
    this.x4v = -this.a3v * this.dsv.sing + this.a4v * this.dsv.cosg;
    this.x5v = this.a5v * this.dsv.sing;
    this.x6v = this.a6v * this.dsv.sing;
    this.x7v = this.a5v * this.dsv.cosg;
    this.x8v = this.a6v * this.dsv.cosg;
    this.z31 = 12 * this.x1v * this.x1v - 3.0 * this.x3v * this.x3v;
    this.z32 = 24 * this.x1v * this.x2v - 6 * this.x3v * this.x4v;
    this.z33 = 12 * this.x2v * this.x2v - 3.0 * this.x4v * this.x4v;
    this.z1 = 3.0 * (this.a1v * this.a1v + this.a2v * this.a2v) + this.z31 * this.dsv.eosq;
    this.z2 = 6.0 * (this.a1v * this.a3v + this.a2v * this.a4v) + this.z32 * this.dsv.eosq;
    this.z3 = 3.0 * (this.a3v * this.a3v + this.a4v * this.a4v) + this.z33 * this.dsv.eosq;
    this.z11 = -6 * this.a1v * this.a5v + this.dsv.eosq * (-24 * this.x1v * this.x7v - 6 * this.x3v * this.x5v);
    this.z12 =
      -6 * (this.a1v * this.a6v + this.a3v * this.a5v) +
      this.dsv.eosq * (-24 * (this.x2v * this.x7v + this.x1v * this.x8v) - 6 * (this.x3v * this.x6v + this.x4v * this.x5v));
    this.z13 = -6 * this.a3v * this.a6v + this.dsv.eosq * (-24 * this.x2v * this.x8v - 6 * this.x4v * this.x6v);
    this.z21 = 6.0 * this.a2v * this.a5v + this.dsv.eosq * (24 * this.x1v * this.x5v - 6 * this.x3v * this.x7v);
    this.z22 =
      6.0 * (this.a4v * this.a5v + this.a2v * this.a6v) +
      this.dsv.eosq * (24 * (this.x2v * this.x5v + this.x1v * this.x6v) - 6 * (this.x4v * this.x7v + this.x3v * this.x8v));
    this.z23 = 6.0 * this.a4v * this.a6v + this.dsv.eosq * (24 * this.x2v * this.x6v - 6 * this.x4v * this.x8v);
    this.z1 += this.z1 + this.dsv.betao2 * this.z31;
    this.z2 += this.z2 + this.dsv.betao2 * this.z32;
    this.z3 += this.z3 + this.dsv.betao2 * this.z33;
    this.s3 = this.cc * this.xnoi;
    this.s2 = -0.5 * this.s3 / this.dsv.betao;
    this.s4num = this.s3 * this.dsv.betao;
    this.s1 = -15 * this.eq * this.s4num;
    this.s5 = this.x1v * this.x3v + this.x2v * this.x4v;
    this.s6 = this.x2v * this.x3v + this.x1v * this.x4v;
    this.s7 = this.x2v * this.x4v - this.x1v * this.x3v;
    this.se = this.s1 * this.zn * this.s5;
    this.si = this.s2 * this.zn * (this.z11 + this.z13);
    this.sl = -this.zn * this.s3 * (this.z1 + this.z3 - 14 - 6 * this.dsv.eosq);
    this.sgh = this.s4num * this.zn * (this.z31 + this.z33 - 6);
    this.sh = -this.zn * this.s2 * (this.z21 + this.z23);
    if (this.xqncl < 5.2359877E-2) {
      this.sh = 0.0;
    }
    this.ee2 = 2.0 * this.s1 * this.s6;
    this.e3 = 2.0 * this.s1 * this.s7;
    this.xi2 = 2.0 * this.s2 * this.z12;
    this.xi3 = 2.0 * this.s2 * (this.z13 - this.z11);
    this.xl2 = -2 * this.s3 * this.z2;
    this.xl3 = -2 * this.s3 * (this.z3 - this.z1);
    this.xl4 = -2 * this.s3 * (-21 - 9 * this.dsv.eosq) * this.ze;
    this.xgh2 = 2.0 * this.s4num * this.z32;
    this.xgh3 = 2.0 * this.s4num * (this.z33 - this.z31);
    this.xgh4 = -18 * this.s4num * this.ze;
    this.xh2 = -2 * this.s2 * this.z22;
    this.xh3 = -2 * this.s2 * (this.z23 - this.z21);
  }

  private processEpochRestartLoop(): void {
    if (this.atime === 0.0 || (this.dsv.t >= 0 && this.atime < 0) || (this.dsv.t < 0 && this.atime >= 0)) {
      this.calculateDelta();
      this.atime = 0.0;
      this.xni = this.xnq;
      this.xli = this.xlamo;
    } else if (Math.abs(this.dsv.t) >= Math.abs(this.atime)) {
      this.calculateDelta();
    }
    this.processNotEpochRestartLoop();
  }

  private calculateDelta(): void {
    this.delt = this.dsv.t < 0 ? this.stepn : this.stepp;
  }

  private processNotEpochRestartLoop(): void {
    do {
      if (Math.abs(this.dsv.t - this.atime) >= this.stepp) {
        this.doLoop = true;
        this.epochRestart = false;
      } else {
        this.ft = this.dsv.t - this.atime;
        this.doLoop = false;
      }
      if (Math.abs(this.dsv.t) < Math.abs(this.atime)) {
        this.delt = this.dsv.t >= 0 ? this.stepn : this.stepp;
        this.doLoop = this.doLoop || this.epochRestart;
      }
      if (this.synchronous) {
        this.xndot = this.del1 * Math.sin(this.xli - this.fasx2) + this.del2 * Math.sin(2.0 * (this.xli - this.fasx4))
          + this.del3 * Math.sin(3.0 * (this.xli - this.fasx6));
        this.xnddt = this.del1 * Math.cos(this.xli - this.fasx2) + 2 * this.del2 * Math.cos(2.0 * (this.xli - this.fasx4))
          + 3.0 * this.del3 * Math.cos(3.0 * (this.xli - this.fasx6));
      } else {
        this.xomi = this.omegaq + this.dsv.omgdot * this.atime;
        this.x2omi = this.xomi + this.xomi;
        this.x2li = this.xli + this.xli;
        this.xndot =
          this.d2201 * Math.sin(this.x2omi + this.xli - this.g22) + this.d2211 * Math.sin(this.xli - this.g22) +
          (this.d3210 * Math.sin(this.xomi + this.xli - this.g32)) +
          this.d3222 * Math.sin(-this.xomi + this.xli - this.g32) +
          (this.d4410 * Math.sin(this.x2omi + this.x2li - this.g44)) +
          this.d4422 * Math.sin(this.x2li - this.g44) +
          (this.d5220 * Math.sin(this.xomi + this.xli - this.g52)) +
          this.d5232 * Math.sin(-this.xomi + this.xli - this.g52) +
          (this.d5421 * Math.sin(this.xomi + this.x2li - this.g54)) +
          this.d5433 * Math.sin(-this.xomi + this.x2li - this.g54);
        this.xnddt =
          this.d2201 * Math.cos(this.x2omi + this.xli - this.g22) + this.d2211 * Math.cos(this.xli - this.g22) +
          (this.d3210 * Math.cos(this.xomi + this.xli - this.g32)) +
          this.d3222 * Math.cos(-this.xomi + this.xli - this.g32) +
          (this.d5220 * Math.cos(this.xomi + this.xli - this.g52)) +
          this.d5232 * Math.cos(-this.xomi + this.xli - this.g52) +
          (2 * (this.d4410 * Math.cos(this.x2omi + this.x2li - this.g44) +
          this.d4422 * Math.cos(this.x2li - this.g44) +
          (this.d5421 * Math.cos(this.xomi + this.x2li - this.g54)) +
          this.d5433 * Math.cos(-this.xomi + this.x2li - this.g54)));
      }
      this.xldot = this.xni + this.xfact;
      this.xnddt *= this.xldot;
      if (this.doLoop) {
        this.xli += this.xldot * this.delt + this.xndot * this.step2;
        this.xni += this.xndot * this.delt + this.xnddt * this.step2;
        this.atime += this.delt;
      }
    } while (this.doLoop && !this.epochRestart);
  }

  private applyPeriodics(): void {
    this.sinok = Math.sin(this.dsv.xnode);
    this.cosok = Math.cos(this.dsv.xnode);
    this.alfdp = this.sinis * this.sinok;
    this.betdp = this.sinis * this.cosok;
    this.dalf = this.ph * this.cosok + this.pinc * this.cosis * this.sinok;
    this.dbet = -this.ph * this.sinok + this.pinc * this.cosis * this.cosok;
    this.alfdp += this.dalf;
    this.betdp += this.dbet;
    this.dsv.xnode = mod2PI(this.dsv.xnode);
    this.xls = this.dsv.xll + this.dsv.omgadf + this.cosis * this.dsv.xnode;
    this.dls = this.pl + this.pgh - this.pinc * this.dsv.xnode * this.sinis;
    this.xls += this.dls;
    this.xnoh = this.dsv.xnode;
    this.dsv.xnode = Math.atan2(this.alfdp, this.betdp);
  }

  private thetaG(epoch: number): number {
    let year = Math.floor(epoch * 1E-3);
    let dayOfYear = (epoch * 1E-3 - year) * 1000.0;
    year = year < 57 ? year + 2000 : year + 1900;
    const dayFloor = Math.floor(dayOfYear);
    const dayFraction = dayOfYear - dayFloor;
    dayOfYear = dayFloor;
    const jd = this.julianDateOfYearOuter(year) + dayOfYear;
    this.dsv.ds50 = jd - 2433281.5 + dayFraction;
    return mod2PI(6.3003880987 * this.dsv.ds50 + 1.72944494);
  }

  private julianDateOfYearOuter(year: number): number {
    const aYear = year - 1;
    let i = Math.floor(aYear / 100);
    const a = i;
    i = Math.floor(a / 4);
    const b = 2 - a + i;
    i = Math.floor(365.25 * aYear);
    i += Math.floor(30.6001 * 14);
    return i + 1720994.5 + b;
  }
}