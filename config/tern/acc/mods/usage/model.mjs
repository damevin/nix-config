import { PROVIDERS } from './providers/index.js';
import { nextState } from './lib/state.js';
import { barModel, cardModel } from './lib/view.js';
import { effectivePrefs } from './lib/prefs.js';
import { parseSession, sessionView, sessionOnBar } from './lib/session.js';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const request = JSON.parse(input);
const now = Math.floor(Date.now() / 1000);
if (request.mode === 'parse') {
  const provider = PROVIDERS.find(p => p.id === request.id);
  const report = provider.parse(request.text, now);
  console.log(JSON.stringify(nextState(request.prev, report, request.status !== 127)));
} else if (request.mode === 'session') {
  console.log(JSON.stringify(parseSession(request.text, request.app)));
} else {
  const prefs = effectivePrefs(request.prefs, {});
  const card = cardModel(request.states, now);
  card.session = sessionView(request.session, request.title);
  console.log(JSON.stringify({ bar: barModel(request.states, prefs, now), card, numbers: sessionOnBar(request.session, prefs) }));
}
