// Smoke test: verify all endpoints respond under minimal load
import http from 'k6/http';
import { check, sleep } from 'k6';
import { BASE_URL, TEST_DATA } from './config.js';

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    http_req_failed: ['rate==0'],
    http_req_duration: ['p(95)<5000'],
  },
};

const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };

export default function () {
  let res;

  res = http.post(`${BASE_URL}/rpc/get_reptracker_version`);
  check(res, {
    'get_reptracker_version returns 200': (r) => r.status === 200,
    'get_reptracker_version returns data': (r) => r.body.length > 2,
  });
  sleep(0.1);

  res = http.post(`${BASE_URL}/rpc/get_rep_last_synced_block`);
  check(res, {
    'get_rep_last_synced_block returns 200': (r) => r.status === 200,
    'get_rep_last_synced_block returns number': (r) => !isNaN(JSON.parse(r.body)),
  });
  sleep(0.1);

  res = http.post(`${BASE_URL}/rpc/get_account_reputation`, 'account-name=dantheman', { headers });
  check(res, {
    'get_account_reputation returns 200': (r) => r.status === 200,
    'get_account_reputation returns data': (r) => r.body.length > 2,
  });
}
