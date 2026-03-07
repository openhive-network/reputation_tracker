// Load test: sustained traffic across all endpoints
import http from 'k6/http';
import { check, sleep } from 'k6';
import { BASE_URL, DEFAULT_THRESHOLDS, TEST_DATA } from './config.js';

const DURATION = __ENV.DURATION || '2m';
const VUS = parseInt(__ENV.VUS || '10');

export const options = {
  stages: [
    { duration: '15s', target: VUS },
    { duration: DURATION, target: VUS },
    { duration: '10s', target: 0 },
  ],
  thresholds: DEFAULT_THRESHOLDS,
};

const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);

  http.post(`${BASE_URL}/rpc/get_reptracker_version`);

  http.post(`${BASE_URL}/rpc/get_rep_last_synced_block`);

  const res = http.post(`${BASE_URL}/rpc/get_account_reputation`,
    `account-name=${account}`, { headers });
  check(res, { 'reputation ok': (r) => r.status === 200 });

  sleep(0.3);
}
