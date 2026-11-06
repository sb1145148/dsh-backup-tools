#!/usr/bin/env node
/**
 * inspect-sessions.mjs —— 读 DSH 的会话文件，报格式 / seq 连续 / 空会话
 *
 * 用法：
 *   node inspect-sessions.mjs <sessions目录>        # 人读
 *   node inspect-sessions.mjs <sessions目录> --json # 机器读
 *
 * 为什么需要它：
 *   session.v4.jsonl.zstd 是「两个 zstd 帧」：首帧是 header（一行），
 *   其余帧是事件。Node 的 zstdDecompressSync 只解第一帧，
 *   所以要按帧魔数切开，失败时再合并重试。
 */
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

function frameOffsets(buf) {
  const offs = [0];
  for (let i = 1; i < buf.length - 3; i++) {
    if (buf[i] === MAGIC[0] && buf[i + 1] === MAGIC[1] && buf[i + 2] === MAGIC[2] && buf[i + 3] === MAGIC[3]) {
      offs.push(i);
    }
  }
  return offs;
}

/** 解压所有 zstd 帧。切错了会把两帧合起来重试，保证不丢内容。 */
function decodeAllFrames(buf) {
  const offs = frameOffsets(buf);
  offs.push(buf.length);
  let text = '';
  let i = 0;
  while (i < offs.length - 1) {
    let j = i + 1;
    let ok = false;
    while (j < offs.length) {
      const seg = buf.subarray(offs[i], offs[j]);
      try {
        text += zlib.zstdDecompressSync(seg).toString('utf8');
        ok = true;
        break;
      } catch {
        j++; // 这个切点是假的，吞掉下一个帧边界再试
      }
    }
    if (!ok) throw new Error(`帧 ${i} 起无法解压`);
    i = j;
  }
  return text;
}

function inspectFile(file) {
  const buf = fs.readFileSync(file);
  const text = decodeAllFrames(buf);
  const lines = text.split('\n').filter(Boolean);

  let header = null;
  const seqs = [];
  for (const line of lines) {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      return { file, ok: false, reason: 'JSON 解析失败（可能有撕裂行）' };
    }
    if (obj.type === 'session') header = obj;
    else if (typeof obj.seq === 'number') seqs.push(obj.seq);
  }

  if (!header) return { file, ok: false, reason: '没有 header（首行不是 session 记录）' };

  let gaps = 0;
  let firstGap = null;
  for (let i = 1; i < seqs.length; i++) {
    if (seqs[i] !== seqs[i - 1] + 1) {
      gaps++;
      if (!firstGap) firstGap = [seqs[i - 1], seqs[i]];
    }
  }

  const empty = seqs.length === 0;
  return {
    file,
    ok: true,
    id: header.id,
    version: header.version,
    cwd: header.cwd,
    events: seqs.length,
    seqMin: seqs.length ? Math.min(...seqs) : null,
    seqMax: seqs.length ? Math.max(...seqs) : null,
    gaps,
    firstGap,
    empty,
    bytes: buf.length,
  };
}

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else if (entry.name === 'session.v4.jsonl.zstd') out.push(p);
  }
  return out;
}

function main() {
  const args = process.argv.slice(2);
  const dir = args.find((a) => !a.startsWith('--'));
  const asJson = args.includes('--json');
  if (!dir) {
    console.error('用法: node inspect-sessions.mjs <sessions目录> [--json]');
    process.exit(2);
  }
  if (!fs.existsSync(dir)) {
    console.error(`找不到目录: ${dir}`);
    process.exit(2);
  }

  const files = walk(dir);
  const results = files.map((f) => {
    try {
      return inspectFile(f);
    } catch (e) {
      return { file: f, ok: false, reason: e.message };
    }
  });

  const bad = results.filter((r) => !r.ok);
  const gapped = results.filter((r) => r.ok && r.gaps > 0);
  const empty = results.filter((r) => r.ok && r.empty);
  const versions = [...new Set(results.filter((r) => r.ok).map((r) => r.version))];

  const summary = {
    sessions: results.length,
    unreadable: bad.length,
    gaps: gapped.length,
    empty: empty.length,
    versions,
    totalEvents: results.filter((r) => r.ok).reduce((s, r) => s + r.events, 0),
  };

  if (asJson) {
    console.log(JSON.stringify({ summary, results }, null, 2));
    return;
  }

  console.log(`会话: ${summary.sessions} 个 | 格式: v${versions.join(',v') || '?'} | 事件: ${summary.totalEvents}`);
  console.log(`读不了: ${summary.unreadable} | seq 断档: ${summary.gaps} | 空会话: ${summary.empty}`);
  for (const r of bad) console.log(`  ❌ ${r.file}\n     ${r.reason}`);
  for (const r of gapped) console.log(`  ⚠️  ${r.id} seq 断档 ${r.gaps} 处，首个: ${JSON.stringify(r.firstGap)}`);
  for (const r of empty) console.log(`  ℹ️  ${r.id} 是空会话（只有 header）`);

  process.exit(bad.length || gapped.length ? 1 : 0);
}

main();
