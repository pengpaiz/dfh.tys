/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import {
  CK2, CK4, EARTH_RADIUS, J3_HARMONIC, TWO_THIRDS, XKE, TWO_PI
} from './Constants';
import { SatOrbitalData } from './OrbitalData';
import { SatOrbitalObject } from './OrbitalObject';
import { mod2PI } from '../../common/utils/MathUtils';

export class SatNearEarthObject extends SatOrbitalObject {
  private readonly aodp: number;
  private readonly aycof: number;
  private readonly c1: number;
  private readonly c4: number;
  private readonly c5: number;
  private readonly cosio: number;
  private d2 = 0.0;
  private d3 = 0.0;
  private d4 = 0.0;
  private readonly delmo: number;
  private readonly omgcof: number;
  private readonly eta: number;
  private readonly omgdot: number;
  private readonly sinio: number;
  private readonly xnodp: number;
  private readonly sinmo: number;
  private readonly t2cof: number;
  private t3cof = 0.0;
  private t4cof = 0.0;
  private t5cof = 0.0;
  private readonly x1mth2: number;
  private readonly x3thm1: number;
  private readonly x7thm1: number;
  private readonly xmcof: number;
  private readonly xmdot: number;
  private readonly xnodcf: number;
  private readonly xnodot: number;
  private readonly xlcof: number;
  private readonly sgp4Simple: boolean;

  constructor(data: SatOrbitalData) {
    super(data);
    const a1 = Math.pow(XKE / data.xno, TWO_THIRDS);
    this.cosio = Math.cos(data.xincl);
    const theta2 = this.sqr(this.cosio);
    this.x3thm1 = 3.0 * theta2 - 1.0;
    const eo = data.eccn;
    const eosq = this.sqr(eo);
    const betao2 = 1.0 - eosq;
    const betao = Math.sqrt(betao2);
    const del1 = 1.5 * CK2 * this.x3thm1 / (this.sqr(a1) * betao * betao2);
    const ao = a1 * (1.0 - del1 * (0.5 * TWO_THIRDS + del1 * (1.0 + 134.0 / 81.0 * del1)));
    const delo = 1.5 * CK2 * this.x3thm1 / (this.sqr(ao) * betao * betao2);
    this.xnodp = data.xno / (1.0 + delo);
    this.aodp = ao / (1.0 - delo);

    this.sgp4Simple = this.aodp * (1.0 - eo) < 220 / EARTH_RADIUS + 1.0;

    this.setPerigee((this.aodp * (1.0 - eo) - 1.0) * EARTH_RADIUS);
    const pinvsq = this.invert(this.sqr(this.aodp) * this.sqr(betao2));
    const tsi = this.invert(this.aodp - this.s4);
    this.eta = this.aodp * eo * tsi;
    const etasq = this.eta * this.eta;
    const eeta = eo * this.eta;
    const psisq = Math.abs(1.0 - etasq);
    const coef = this.qoms24 * Math.pow(tsi, 4.0);
    const coef1 = coef / Math.pow(psisq, 3.5);
    const bstar = data.bstar;
    const c2 = coef1 * this.xnodp * (this.aodp * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq)) + 0.75
      * CK2 * tsi / psisq * this.x3thm1 * (8.0 + 3.0 * etasq * (8.0 + etasq)));
    this.c1 = bstar * c2;
    this.sinio = Math.sin(data.xincl);
    const a3ovk2 = -J3_HARMONIC / CK2;
    const c3 = coef * tsi * a3ovk2 * this.xnodp * this.sinio / eo;
    this.x1mth2 = 1.0 - theta2;
    const omegao = data.omegao;
    this.c4 = 2 * this.xnodp * coef1 * this.aodp * betao2 * (this.eta * (2.0 + 0.5 * etasq) +
      eo * (0.5 + 2 * etasq) - 2 * CK2 * tsi / (this.aodp * psisq) * (-3 * this.x3thm1 *
      (1.0 - 2 * eeta + etasq * (1.5 - 0.5 * eeta)) + 0.75 * this.x1mth2 * (2.0 * etasq - eeta *
      (1.0 + etasq)) * Math.cos(2.0 * omegao)));
    this.c5 = 2.0 * coef1 * this.aodp * betao2 * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq);
    const theta4 = this.sqr(theta2);
    const temp1 = 3.0 * CK2 * pinvsq * this.xnodp;
    const temp2 = temp1 * CK2 * pinvsq;
    const temp3 = 1.25 * CK4 * pinvsq * pinvsq * this.xnodp;
    this.xmdot =
      this.xnodp + 0.5 * temp1 * betao * this.x3thm1 + (0.0625 * temp2 * betao * (13.0 - 78.0 * theta2 + 137.0 * theta4));
    const x1m5th = 1.0 - 5.0 * theta2;
    this.omgdot =
      -0.5 * temp1 * x1m5th + 0.0625 * temp2 * (7.0 - 114.0 * theta2 + 395.0 * theta4) +
      temp3 * (3.0 - 36.0 * theta2 + 49.0 * theta4);
    const xhdot1 = -temp1 * this.cosio;
    this.xnodot =
      xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * theta2) + 2.0 * temp3 * (3.0 - 7.0 * theta2)) * this.cosio;
    this.omgcof = bstar * c3 * Math.cos(omegao);
    this.xmcof = -TWO_THIRDS * coef * bstar / eeta;
    this.xnodcf = 3.5 * betao2 * xhdot1 * this.c1;
    this.t2cof = 1.5 * this.c1;
    this.xlcof = 0.125 * a3ovk2 * this.sinio * (3.0 + 5 * this.cosio) / (1.0 + this.cosio);
    this.aycof = 0.25 * a3ovk2 * this.sinio;
    const xmo = data.xmo;
    this.delmo = Math.pow(1.0 + this.eta * Math.cos(xmo), 3.0);
    this.sinmo = Math.sin(xmo);
    this.x7thm1 = 7.0 * theta2 - 1;
    if (!this.sgp4Simple) {
      const c1sq = this.sqr(this.c1);
      this.d2 = 4.0 * this.aodp * tsi * c1sq;
      const temp = this.d2 * tsi * this.c1 / 3.0;
      this.d3 = (17 * this.aodp + this.s4) * temp;
      this.d4 = 0.5 * temp * this.aodp * tsi * (221 * this.aodp + 31 * this.s4) * this.c1;
      this.t3cof = this.d2 + 2 * c1sq;
      this.t4cof = 0.25 * (3.0 * this.d3 + this.c1 * (12 * this.d2 + 10 * c1sq));
      this.t5cof = 0.2 * (3.0 * this.d4 + 12 * this.c1 * this.d3 + 6 * this.d2 * this.d2 +
        15 * c1sq * (2.0 * this.d2 + c1sq));
    } else {
      this.d2 = 0.0;
      this.d3 = 0.0;
      this.d4 = 0.0;
      this.t3cof = 0.0;
      this.t4cof = 0.0;
      this.t5cof = 0.0;
    }
  }

  protected propagate(tSince: number): void {
    this.calculateSGP4(tSince);
  }

  calculateSGP4(tSince: number): void {
    const temp = new Array<number>(9);
    const xmdf = this.data.xmo + this.xmdot * tSince;
    const omgadf = this.data.omegao + this.omgdot * tSince;
    const xnoddf = this.data.xnodeo + this.xnodot * tSince;
    let omega = omgadf;
    let xmp = xmdf;
    const tsq = tSince * tSince;
    const xnode = xnoddf + this.xnodcf * tsq;
    const bstar = this.data.bstar;
    let tempa = 1.0 - this.c1 * tSince;
    let tempe = bstar * this.c4 * tSince;
    let templ = this.t2cof * tsq;
    if (!this.sgp4Simple) {
      const delomg = this.omgcof * tSince;
      const delm = this.xmcof * (Math.pow(1.0 + this.eta * Math.cos(xmdf), 3.0) - this.delmo);
      temp[0] = delomg + delm;
      xmp = xmdf + temp[0];
      omega = omgadf - temp[0];
      const tcube = tsq * tSince;
      const tfour = tSince * tcube;
      tempa = tempa - this.d2 * tsq - this.d3 * tcube - this.d4 * tfour;
      tempe += bstar * this.c5 * (Math.sin(xmp) - this.sinmo);
      templ += this.t3cof * tcube + tfour * (this.t4cof + tSince * this.t5cof);
    }
    const a = this.aodp * tempa * tempa;
    const eo = this.data.eccn;
    const e = eo - tempe;
    const xl = xmp + omega + xnode + this.xnodp * templ;
    const beta = Math.sqrt(1.0 - e * e);
    const xn = XKE / Math.pow(a, 1.5);

    const axn = e * Math.cos(omega);
    temp[0] = this.invert(a * this.sqr(beta));
    const xll = temp[0] * this.xlcof * axn;
    const aynl = temp[0] * this.aycof;
    const xlt = xl + xll;
    const ayn = e * Math.sin(omega) + aynl;

    const capu = mod2PI(xlt - xnode);
    temp[2] = capu;
    this.converge(temp, axn, ayn, capu);
    this.calculateSGP4PosVel(temp, xnode, a, xn, axn, ayn);
    this.calculatePhase(xlt, xnode, omgadf);
  }

  private calculateSGP4PosVel(
    temp: number[], xnode: number, a: number,
    xn: number, axn: number, ayn: number
  ): void {
    const ecose = temp[5] + temp[6];
    const esine = temp[3] - temp[4];
    const elsq = this.sqr(axn) + this.sqr(ayn);
    temp[0] = 1.0 - elsq;
    const pl = a * temp[0];
    const r = a * (1.0 - ecose);
    temp[1] = this.invert(r);
    const rdot = XKE * Math.sqrt(a) * esine * temp[1];
    const rfdot = XKE * Math.sqrt(pl) * temp[1];
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
    const rk = r * (1.0 - 1.5 * temp[2] * betal * this.x3thm1) + 0.5 * temp[1] * this.x1mth2 * cos2u;
    const uk = u - 0.25 * temp[2] * this.x7thm1 * sin2u;
    const xnodek = xnode + 1.5 * temp[2] * this.cosio * sin2u;
    const xinck = this.data.xincl + 1.5 * temp[2] * this.cosio * this.sinio * cos2u;
    const rdotk = rdot - xn * temp[1] * this.x1mth2 * sin2u;
    const rfdotk = rfdot + xn * temp[1] * (this.x1mth2 * cos2u + 1.5 * this.x3thm1);
    super.calculatePosAndVel(rk, uk, xnodek, xinck, rdotk, rfdotk);
  }
}