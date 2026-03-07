// Shared configuration for k6 performance tests

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

export const DEFAULT_THRESHOLDS = {
  http_req_duration: ['p(95)<2000', 'p(99)<5000'],
  http_req_failed: ['rate<0.01'],
};

// PostgREST RPC helper - POST to rpc/<function> with form-encoded params
export function rpcPost(endpoint, params) {
  const qs = Object.entries(params || {})
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');
  return { url: `${BASE_URL}/rpc/${endpoint}`, body: qs || null };
}

// Test data matching the 5M block CI dataset
export const TEST_DATA = {
  accounts: ['dantheman', 'ned', 'blocktrades', 'steemit', 'smooth'],
};
