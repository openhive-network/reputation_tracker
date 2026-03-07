// Stress test: push the API beyond normal load to find breaking points
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { BASE_URL, TEST_DATA } from './config.js';

const errorRate = new Rate('errors');
const MAX_VUS = parseInt(__ENV.MAX_VUS || '50');

export const options = {
  stages: [
    { duration: '30s', target: Math.floor(MAX_VUS * 0.2) },
    { duration: '1m', target: Math.floor(MAX_VUS * 0.5) },
    { duration: '1m', target: MAX_VUS },
    { duration: '1m', target: MAX_VUS },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<5000'],
    errors: ['rate<0.10'],
  },
};

const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// Weighted endpoint selection: reputation lookups are the heavy endpoint
const ENDPOINTS = [
  { weight: 60, fn: getReputation },
  { weight: 20, fn: getVersion },
  { weight: 20, fn: getLastSyncedBlock },
];

const WEIGHTED = [];
for (const ep of ENDPOINTS) {
  for (let i = 0; i < ep.weight; i++) WEIGHTED.push(ep.fn);
}

function getReputation() {
  return http.post(`${BASE_URL}/rpc/get_account_reputation`,
    `account-name=${randomItem(TEST_DATA.accounts)}`, { headers });
}

function getVersion() {
  return http.post(`${BASE_URL}/rpc/get_reptracker_version`);
}

function getLastSyncedBlock() {
  return http.post(`${BASE_URL}/rpc/get_rep_last_synced_block`);
}

export default function () {
  const fn = WEIGHTED[Math.floor(Math.random() * WEIGHTED.length)];
  const res = fn();
  check(res, { 'not server error': (r) => r.status < 500 });
  errorRate.add(res.status >= 500);
  sleep(0.1 + Math.random() * 0.3);
}
