#!/usr/bin/env node
/* Synthesized 34.0s stereo soundtrack -> soundtrack.wav (44.1kHz 16-bit)
 * 90 BPM, A-minor pad progression, light beat from the scan scene,
 * riser + impact at the "clean complete" moment, warm outro.
 */
const fs = require("fs");
const path = require("path");

const SR = 44100, DUR = 34.0, N = Math.round(SR * DUR);
const BPM = 90, BEAT = 60 / BPM, BAR = BEAT * 4;

const L = new Float32Array(N), R = new Float32Array(N);
const duck = new Float32Array(N); // kick envelope for sidechain

const add = (buf, i, v) => { if (i >= 0 && i < N) buf[i] += v; };
function lcg(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
const rnd = lcg(20261001);

/* ---- instruments ---- */
function padNote(t0, dur, freq, pan, gain) {
  const i0 = Math.round(t0 * SR), len = Math.round((dur + 1.2) * SR);
  const a = 2 * Math.PI * freq, det = 1.0025;
  let lpL = 0, lpR = 0; const cut = 1 - Math.exp(-2 * Math.PI * 950 / SR);
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const env = Math.min(1, t / 0.7) * Math.exp(-Math.max(0, t - dur) * 2.2) * (t < dur ? 1 : 0) || Math.exp(-Math.max(0, t - dur) * 2.2) * Math.min(1, t / 0.7);
    const e = Math.min(1, t / 0.7) * Math.exp(-Math.max(0, t - dur) * 2.4);
    const wL = Math.sin(a * (1 - 0.00125) * t) * 0.6 + Math.sin(a * (1 - 0.00125) * 2 * t + 0.7) * 0.18 + Math.sin(a * 0.5 * (1 - 0.00125) * t) * 0.35;
    const wR = Math.sin(a * (1 + 0.00125) * t + 1.3) * 0.6 + Math.sin(a * (1 + 0.00125) * 2 * t + 2.1) * 0.18 + Math.sin(a * 0.5 * (1 + 0.00125) * t) * 0.35;
    lpL += cut * (wL * e - lpL); lpR += cut * (wR * e - lpR);
    const i = i0 + j;
    add(L, i, lpL * gain * (1 - Math.max(0, pan)));
    add(R, i, lpR * gain * (1 + Math.min(0, pan)));
  }
}
function bassNote(t0, dur, freq, gain) {
  const i0 = Math.round(t0 * SR), len = Math.round((dur + 0.4) * SR);
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const e = Math.min(1, t / 0.03) * (1 - Math.exp(-Math.max(0, t - dur + 0.15) * 12) * 0) ;
    const rel = t > dur - 0.12 ? Math.max(0, (dur - t) / 0.12) : 1;
    const v = Math.tanh((Math.sin(2 * Math.PI * freq * t) * 0.8 + Math.sin(2 * Math.PI * freq * 2 * t) * 0.12) * 1.6) * e * rel * gain;
    const i = i0 + j; add(L, i, v); add(R, i, v);
  }
}
function pluck(t0, freq, gain, pan) {
  const i0 = Math.round(t0 * SR), len = Math.round(0.34 * SR);
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const e = Math.exp(-t * 11) * Math.min(1, t / 0.004);
    const v = (Math.sin(2 * Math.PI * freq * t) * 0.75 + Math.sin(2 * Math.PI * freq * 2 * t) * 0.2 * Math.exp(-t * 18)) * e * gain;
    const i = i0 + j;
    add(L, i, v * (1 - Math.max(0, pan))); add(R, i, v * (1 + Math.min(0, pan)));
  }
}
function kick(t0, gain) {
  const i0 = Math.round(t0 * SR), len = Math.round(0.24 * SR);
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const f = 58 * Math.exp(-t * 26) + 38;
    const e = Math.exp(-t * 15) * Math.min(1, t / 0.002);
    const v = Math.sin(2 * Math.PI * f * t) * e * gain;
    const i = i0 + j; add(L, i, v); add(R, i, v);
    if (i < N) duck[i] = Math.max(duck[i], e);
  }
}
let noiseState = 0.5;
function nrand() { noiseState = (noiseState * 16807) % 2147483647; return noiseState / 2147483647 - 0.5; }
function hat(t0, gain, open = false) {
  const i0 = Math.round(t0 * SR), len = Math.round((open ? 0.12 : 0.045) * SR);
  let hp = 0, prev = 0;
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const x = nrand();
    hp = 0.72 * (hp + x - prev); prev = x;
    const e = Math.exp(-t * (open ? 34 : 90)) * Math.min(1, t / 0.001);
    const v = hp * e * gain;
    const i = i0 + j; add(L, i, v * 0.82); add(R, i, v * 1.12);
  }
}
function bell(t0, freq, gain, pan = 0) {
  const i0 = Math.round(t0 * SR), len = Math.round(2.4 * SR);
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const e = Math.exp(-t * 2.1) * Math.min(1, t / 0.004);
    const v = (Math.sin(2 * Math.PI * freq * t) + Math.sin(2 * Math.PI * freq * 2.756 * t) * 0.4 * Math.exp(-t * 4) + Math.sin(2 * Math.PI * freq * 5.404 * t) * 0.14 * Math.exp(-t * 7)) * e * gain;
    const i = i0 + j;
    add(L, i, v * (1 - Math.max(0, pan))); add(R, i, v * (1 + Math.min(0, pan)));
  }
}
function riser(t0, dur, gain) {
  const i0 = Math.round(t0 * SR), len = Math.round(dur * SR);
  let lp = 0, prev = 0, hp = 0;
  for (let j = 0; j < len; j++) {
    const t = j / SR, k = t / dur;
    const x = nrand();
    hp = 0.7 * (hp + x - prev); prev = x;
    const cut = 1 - Math.exp(-2 * Math.PI * (500 + 5200 * k * k) / SR);
    lp += cut * (hp - lp);
    const e = k * k * gain;
    const sweep = Math.sin(2 * Math.PI * (170 + 560 * k * k) * t) * 0.4 * e;
    const i = i0 + j; add(L, i, (lp * e + sweep) * 0.95); add(R, i, (lp * e + sweep));
  }
}
function impact(t0) {
  const i0 = Math.round(t0 * SR), len = Math.round(1.0 * SR);
  let lp = 0; const cut = 1 - Math.exp(-2 * Math.PI * 900 / SR);
  for (let j = 0; j < len; j++) {
    const t = j / SR;
    const f = 72 * Math.exp(-t * 9) + 30;
    const e = Math.exp(-t * 5.2) * Math.min(1, t / 0.002);
    const sub = Math.sin(2 * Math.PI * f * t) * e * 0.55;
    lp += cut * (nrand() * Math.exp(-t * 22) - lp);
    const v = sub + lp * 0.4 * e;
    const i = i0 + j; add(L, i, v); add(R, i, v);
    if (i < N) duck[i] = Math.max(duck[i], Math.exp(-t * 4));
  }
}

/* ---- arrangement ---- */
const CHORDS = [
  { bass: 55.00, tones: [220.00, 261.63, 329.63, 392.00] },   // Am7
  { bass: 43.65, tones: [174.61, 220.00, 261.63, 329.63] },   // Fmaj7
  { bass: 65.41, tones: [261.63, 329.63, 392.00, 493.88] },   // Cmaj7
  { bass: 49.00, tones: [196.00, 246.94, 293.66, 440.00] }    // Gadd9
];
const chordAt = t => CHORDS[Math.floor(t / BAR) % 4];
const PENT = [220.0, 261.63, 293.66, 329.63, 392.0, 440.0, 523.25];

// pad across whole track (skip last 0.8s tail ok)
for (let bar = 0; bar * BAR < DUR - 1; bar++) {
  const ch = chordAt(bar * BAR + 0.01);
  ch.tones.forEach((f, i) => padNote(bar * BAR, BAR + 0.4, f, (i % 2 ? 0.5 : -0.5), 0.031));
}
// hook: sub swells only
bassNote(1.2, 2.2, 55.0, 0.10);
bassNote(3.6, 1.8, 43.65, 0.085);
// brand: bass becomes steady
for (let t = 5.6; t < 9.8; t += BAR) bassNote(t, BAR - 0.05, chordAt(t + 0.01).bass, 0.15);
// scan: bass + light beat
for (let t = 9.8; t < 17.0 - 1e-6; t += BAR) bassNote(t, BAR - 0.05, chordAt(t + 0.01).bass, 0.16);
for (let b = 0; b * BEAT < 17.0 - 9.8; b++) {
  const t = 9.8 + b * BEAT;
  kick(t, b % 4 === 0 ? 0.30 : 0.22);
  hat(t + BEAT / 2, 0.045);
}
// arp (8ths) through scan
for (let s = 0; s * BEAT / 2 + 9.8 < 17.0; s++) {
  const t = 9.8 + s * BEAT / 2;
  const f = PENT[Math.floor(rnd() * PENT.length)];
  pluck(t, f, s % 2 ? 0.055 : 0.075, s % 2 ? 0.5 : -0.5);
}
// clean: full beat + 16th arp
for (let t = 17.0; t < 22.25 - 1e-6; t += BAR) bassNote(t, BAR - 0.05, chordAt(t + 0.01).bass, 0.17);
for (let b = 0; b * BEAT + 17.0 < 22.25; b++) {
  const t = 17.0 + b * BEAT;
  kick(t, b % 4 === 0 ? 0.36 : 0.27);
  hat(t + BEAT / 2, 0.06, b % 4 === 2);
  if (b % 2 === 1) hat(t + BEAT / 4, 0.03);
}
for (let s = 0; s * BEAT / 4 + 17.0 < 22.25; s++) {
  const t = 17.0 + s * BEAT / 4;
  const f = PENT[Math.floor(rnd() * PENT.length)];
  pluck(t, f, s % 4 === 0 ? 0.07 : 0.045, s % 2 ? 0.55 : -0.55);
}
riser(21.25, 1.0, 0.13);
impact(22.25);
bell(22.25, 880.0, 0.16, -0.2); bell(22.33, 1174.66, 0.11, 0.3); bell(22.45, 659.26, 0.10, 0.1);
// celebrate beat tail 22.25-23.6
for (let b = 0; b * BEAT + 22.25 < 23.6; b++) { kick(22.25 + b * BEAT, b === 0 ? 0.34 : 0.24); hat(22.25 + b * BEAT + BEAT / 2, 0.05); }
// safety: calm
for (let t = 23.6; t < 27.8 - 1e-6; t += BAR) bassNote(t, BAR - 0.05, chordAt(t + 0.01).bass, 0.13);
for (let s = 0; s * BEAT / 2 + 23.6 < 27.8; s += 2) {
  const t = 23.6 + s * BEAT / 2;
  pluck(t, PENT[Math.floor(rnd() * 5)], 0.05, s % 4 ? 0.4 : -0.4);
}
// outro
for (let t = 27.8; t < 33.2 - 1e-6; t += BAR) bassNote(t, BAR - 0.05, chordAt(t + 0.01).bass, 0.12);
for (let s = 0; s * BEAT / 2 + 27.8 < 33.0; s += 2) {
  const t = 27.8 + s * BEAT / 2;
  pluck(t, PENT[Math.floor(rnd() * PENT.length)], 0.045, s % 4 ? 0.45 : -0.45);
}
bell(28.6, 440.0, 0.08, 0.2);
bell(30.4, 659.26, 0.10, -0.25);
bell(31.9, 880.0, 0.07, 0.15);

/* ---- mixdown ---- */
const outL = new Float32Array(N), outR = new Float32Array(N);
let peak = 0;
for (let i = 0; i < N; i++) {
  const t = i / SR;
  const d = 1 - 0.4 * duck[i];
  let l = (L[i] * 2.4) * d, r = (R[i] * 2.4) * d;
  // gentle master lowpass glue
  l = Math.tanh(l * 1.15) * 0.92; r = Math.tanh(r * 1.15) * 0.92;
  const fin = Math.min(1, t / 0.25), fout = t > 32.3 ? Math.max(0, (33.85 - t) / 1.55) : 1;
  l *= fin * fout; r *= fin * fout;
  outL[i] = l; outR[i] = r;
  const p = Math.max(Math.abs(l), Math.abs(r)); if (p > peak) peak = p;
}
const g = 0.84 / (peak || 1);
const pcm = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
  pcm.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(outL[i] * g * 32767))), i * 4);
  pcm.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(outR[i] * g * 32767))), i * 4 + 2);
}
const hdr = Buffer.alloc(44);
hdr.write("RIFF", 0); hdr.writeUInt32LE(36 + pcm.length, 4); hdr.write("WAVE", 8);
hdr.write("fmt ", 12); hdr.writeUInt32LE(16, 16); hdr.writeUInt16LE(1, 20); hdr.writeUInt16LE(2, 22);
hdr.writeUInt32LE(SR, 24); hdr.writeUInt32LE(SR * 4, 28); hdr.writeUInt16LE(4, 32); hdr.writeUInt16LE(16, 34);
hdr.write("data", 36); hdr.writeUInt32LE(pcm.length, 40);
fs.writeFileSync(path.join(__dirname, "soundtrack.wav"), Buffer.concat([hdr, pcm]));
console.log(`soundtrack.wav written: ${DUR}s, peak ${peak.toFixed(3)}, gain ${g.toFixed(3)}`);
