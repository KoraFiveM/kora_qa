'use strict';

// Binary screenshot upload to the QA panel (POST /uploads, raw image body).
// Lua's PerformHttpRequest only sends text bodies reliably, so the Lua side
// saves the capture to queue/shots/ and asks this file to stream it.
// Runs on FXServer's Node 22. The panel URL and secret are read from the same
// convars as the Lua side and never leave the server.

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { URL } = require('url');

const MAX_BYTES = 8 * 1024 * 1024;
const TYPES = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp' };

function shotsDir() {
    return path.resolve(GetResourcePath(GetCurrentResourceName()), 'queue', 'shots');
}

function inShotsDir(filePath) {
    const relative = path.relative(shotsDir(), path.resolve(filePath));
    return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}

function upload(filePath, query) {
    return new Promise((resolve) => {
        const secret = GetConvar('kora_qa_secret', '');
        const base = (GetConvar('kora_qa_panel_url', '') || 'http://127.0.0.1:47620/qa/game').replace(/\/+$/, '');
        if (!secret) return resolve({ status: 0, body: '{"error":"kora_qa_secret is not set"}' });
        if (typeof filePath !== 'string' || !inShotsDir(filePath)) return resolve({ status: 400, body: '{"error":"bad path"}' });
        const type = TYPES[path.extname(filePath).toLowerCase()];
        if (!type) return resolve({ status: 400, body: '{"error":"bad type"}' });
        let data;
        try { data = fs.readFileSync(filePath); } catch (e) { return resolve({ status: 404, body: '{"error":"missing file"}' }); }
        if (data.length === 0 || data.length > MAX_BYTES) return resolve({ status: 413, body: '{"error":"size"}' });

        let url;
        try { url = new URL(`${base}/uploads${query ? `?${query}` : ''}`); } catch (e) { return resolve({ status: 0, body: '' }); }
        const lib = url.protocol === 'https:' ? https : http;
        const request = lib.request(url, {
            method: 'POST',
            timeout: 20000,
            headers: { 'Content-Type': type, 'Content-Length': data.length, Authorization: `Bearer ${secret}` },
        }, (response) => {
            const chunks = [];
            response.on('data', (chunk) => chunks.push(chunk));
            response.on('end', () => resolve({ status: response.statusCode || 0, body: Buffer.concat(chunks).toString('utf8').slice(0, 4096) }));
        });
        request.on('timeout', () => request.destroy(new Error('timeout')));
        request.on('error', () => resolve({ status: 0, body: '' }));
        request.end(data);
    });
}

on('kora_qa:upload', (id, filePath, query) => {
    // Only this resource's Lua may ask (a local server event cannot come from a client).
    upload(filePath, typeof query === 'string' ? query : '')
        .then((r) => emit('kora_qa:uploaded', id, r.status, r.body))
        .catch(() => emit('kora_qa:uploaded', id, 0, ''));
});
