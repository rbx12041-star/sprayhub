// imgserver.js — one-click image decode for SprayHub.
// SprayHub asks this for decoded pixels instead of LO running node manually:
//   GET http://localhost:17393/decode?url=<url>&w=40&h=36
// Returns the Luau assignment (getgenv().__imgdata = ...) ready for loadstring.
// Same decoder as img2grid.js. Run once: node imgserver.js   (leave it open)
const http = require("http");
const zlib = require("zlib");
const fs = require("fs");

function parsePNG(buf) {
	const SIG = [137, 80, 78, 71, 13, 10, 26, 10];
	for (let i = 0; i < 8; i++) if (buf[i] !== SIG[i]) throw new Error("not a PNG");
	let off = 8;
	let IHDR = null, PLTE = null, TRNS = null, idat = [];
	while (off < buf.length) {
		const len = buf.readUInt32BE(off); off += 4;
		const type = buf.toString("ascii", off, off + 4); off += 4;
		const data = buf.slice(off, off + len); off += len;
		off += 4;
		if (type === "IHDR") IHDR = { w: data.readUInt32BE(0), h: data.readUInt32BE(4), depth: data[8], ctype: data[9], interlace: data[12] };
		else if (type === "PLTE") PLTE = data;
		else if (type === "tRNS") TRNS = data;
		else if (type === "IDAT") idat.push(data);
		else if (type === "IEND") break;
	}
	if (!IHDR) throw new Error("no IHDR");
	if (IHDR.interlace) throw new Error("interlaced PNG unsupported");
	if (IHDR.depth !== 8) throw new Error("bit depth " + IHDR.depth + " unsupported (need 8)");
	const raw = zlib.inflateSync(Buffer.concat(idat));
	const CH = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[IHDR.ctype];
	if (!CH) throw new Error("color type " + IHDR.ctype + " unsupported");
	const bpp = CH, rowLen = IHDR.w * bpp;
	const px = new Uint8Array(IHDR.w * IHDR.h * 4);
	let prev = Buffer.alloc(rowLen, 0);
	for (let y = 0; y < IHDR.h; y++) {
		const s = y * (rowLen + 1);
		const ft = raw[s];
		const cur = raw.slice(s + 1, s + 1 + rowLen);
		for (let x = 0; x < rowLen; x++) {
			const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
			let v = cur[x];
			if (ft === 1) v = (cur[x] + a) & 0xff;
			else if (ft === 2) v = (cur[x] + b) & 0xff;
			else if (ft === 3) v = (cur[x] + ((a + b) >> 1)) & 0xff;
			else if (ft === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); const pr = pa <= pb && pa <= pc ? a : pb <= pc ? b : c; v = (cur[x] + pr) & 0xff; }
			cur[x] = v;
		}
		for (let x = 0; x < IHDR.w; x++) {
			const i = x * bpp, o = (y * IHDR.w + x) * 4;
			if (IHDR.ctype === 0) { px[o] = px[o+1] = px[o+2] = cur[i]; px[o+3] = 255; }
			else if (IHDR.ctype === 2) { px[o] = cur[i]; px[o+1] = cur[i+1]; px[o+2] = cur[i+2]; px[o+3] = 255; }
			else if (IHDR.ctype === 3) { const idx = cur[i]; px[o] = PLTE[idx*3]; px[o+1] = PLTE[idx*3+1]; px[o+2] = PLTE[idx*3+2]; px[o+3] = TRNS && idx < TRNS.length ? TRNS[idx] : 255; }
			else if (IHDR.ctype === 4) { px[o] = px[o+1] = px[o+2] = cur[i]; px[o+3] = cur[i+1]; }
			else if (IHDR.ctype === 6) { px[o] = cur[i]; px[o+1] = cur[i+1]; px[o+2] = cur[i+2]; px[o+3] = cur[i+3]; }
		}
		prev = cur;
	}
	return { w: IHDR.w, h: IHDR.h, px };
}

function downscale(img, maxW, maxH) {
	const scale = Math.min(maxW / img.w, maxH / img.h, 1);
	const nw = Math.max(1, Math.round(img.w * scale));
	const nh = Math.max(1, Math.round(img.h * scale));
	const out = [];
	for (let y = 0; y < nh; y++) {
		const y0 = Math.floor(y * img.h / nh), y1 = Math.max(y0 + 1, Math.floor((y + 1) * img.h / nh));
		for (let x = 0; x < nw; x++) {
			const x0 = Math.floor(x * img.w / nw), x1 = Math.max(x0 + 1, Math.floor((x + 1) * img.w / nw));
			let r = 0, g = 0, b = 0, a = 0, cnt = 0;
			for (let yy = y0; yy < y1; yy++) for (let xx = x0; xx < x1; xx++) {
				const o = (yy * img.w + xx) * 4;
				r += img.px[o]; g += img.px[o+1]; b += img.px[o+2]; a += img.px[o+3]; cnt++;
			}
			out.push([x + 1, y + 1, Math.round(r / cnt), Math.round(g / cnt), Math.round(b / cnt), Math.round(a / cnt)]);
		}
	}
	return { w: nw, h: nh, px: out };
}

// commons.wikimedia.org file pages -> direct image URL via the API
async function resolveImageUrl(src) {
	const m = src.match(/^https?:\/\/commons\.wikimedia\.org\/wiki\/(File:[^?&#]+)/i);
	if (!m) return src;
	const api = "https://commons.wikimedia.org/w/api.php?action=query&titles=" +
		encodeURIComponent(decodeURIComponent(m[1]).replace(/ /g, "_")) +
		"&prop=imageinfo&iiprop=url&format=json";
	const j = await (await fetch(api, { headers: { "User-Agent": "sprayhub-imgserver/1.0" } })).json();
	const page = Object.values(j.query.pages)[0];
	if (!page || !page.imageinfo || !page.imageinfo[0]) throw new Error("wikimedia: no imageinfo for " + m[1]);
	const u = new URL(page.imageinfo[0].url);
	u.search = ""; // strip tracking params
	return u.toString();
}

const server = http.createServer(async (req, res) => {
	try {
		const u = new URL(req.url, "http://x");
		if (u.pathname !== "/decode") { res.writeHead(404); res.end("not found"); return; }
		const src = u.searchParams.get("url");
		if (!src) { res.writeHead(400); res.end("--ERR no url"); return; }
		const maxW = parseInt(u.searchParams.get("w") || "40", 10);
		const maxH = parseInt(u.searchParams.get("h") || "36", 10);
		let direct;
		try { direct = await resolveImageUrl(src); }
		catch (e) { res.writeHead(400); res.end("--ERR " + e.message); return; }
		const fres = await fetch(direct, { redirect: "follow", headers: { "User-Agent": "Mozilla/5.0" } });
		if (!fres.ok) { res.writeHead(400); res.end("--ERR HTTP " + fres.status); return; }
		const buf = Buffer.from(await fres.arrayBuffer());
		const img = downscale(parsePNG(buf), maxW, maxH);
		const parts = [];
		let kept = 0;
		for (const [x, y, r, g, b, a] of img.px) {
			if (a < 32) continue;
			parts.push("{" + x + "," + y + "," + ((r << 16) | (g << 8) | b) + "," + a + "}");
			kept++;
		}
		const lua = "getgenv().__imgdata = {w=" + img.w + ",h=" + img.h + ",n=" + kept + ",px={" + parts.join(",") + "}}\n";
		console.log("decoded " + img.w + "x" + img.h + " (" + kept + "px) for " + src.slice(0, 80));
		res.writeHead(200, { "Content-Type": "text/plain" });
		res.end(lua);
	} catch (e) {
		res.writeHead(500); res.end("--ERR " + e.message);
	}
});
server.listen(17393, "127.0.0.1", () => console.log("[imgserver] listening on http://localhost:17393/decode?url=..."));
