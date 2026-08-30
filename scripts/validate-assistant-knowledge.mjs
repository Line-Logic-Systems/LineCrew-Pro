import fs from 'node:fs';
import vm from 'node:vm';

const index = fs.readFileSync('index.html', 'utf8');
const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts', 'utf8');

const failures = [];
const requireText = (source, text, label) => {
  if (!source.includes(text)) failures.push(`${label}: missing ${text}`);
};

const declaration = 'const assistantBuiltInHelp = [';
const arrayStart = index.indexOf('[', index.indexOf(declaration));
const arrayEndMarker = '\n];\nlet assistantConversation';
const arrayEnd = index.indexOf(arrayEndMarker, arrayStart);

if (arrayStart < 0 || arrayEnd < 0) {
  failures.push('Built-in assistant article array could not be extracted.');
}

let articles = [];
if (!failures.length) {
  try {
    articles = vm.runInNewContext(`(${index.slice(arrayStart, arrayEnd + 2)})`);
  } catch (error) {
    failures.push(`Built-in assistant articles are not valid JavaScript: ${error.message}`);
  }
}

function normalize(question) {
  return String(question || '')
    .toLowerCase()
    .replace(/\b(gf|general foremen)\b/g, 'general foreman')
    .replace(/\b(mh|manhour|manhours)\b/g, 'man hour')
    .replace(/\b(xlsx|xls|spreadsheet)\b/g, 'excel')
    .replace(/\b(upload|load)\b/g, 'import')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function answerFor(question) {
  const normalized = normalize(question);
  let best = null;
  let bestScore = 0;
  for (const article of articles) {
    const score = article.terms.reduce((total, term) => {
      const normalizedTerm = String(term).toLowerCase();
      if (normalized.includes(normalizedTerm)) return total + 3;
      const words = normalizedTerm.split(/\s+/).filter((word) => word.length > 2);
      const matches = words.filter((word) => normalized.includes(word)).length;
      return total + (words.length && matches === words.length ? 2 : matches * 0.25);
    }, 0);
    if (score > bestScore) {
      best = article;
      bestScore = score;
    }
  }
  return best?.answer || '';
}

const promptRoleChecks = [
  ['Owner', 'only role that can authorize an unresolved-work job-close override'],
  ['Admin', 'My Admin Time Roster'],
  ['Superintendent', 'if that capability is enabled'],
  ['General Foreman', 'assigned-crew scope'],
  ['Foreman', 'Remaining Units is a Foreman-only dashboard workspace']
];

for (const [role, marker] of promptRoleChecks) {
  requireText(assistant, marker, `${role} live-AI knowledge`);
}

const scenarios = [
  {
    role: 'Owner',
    question: 'How do I upload our company logo?',
    expected: ['Company Logo', 'printed Daily Reports']
  },
  {
    role: 'Admin',
    question: 'How do I review and lock a pay period for payroll?',
    expected: ['Only Admin/Owner may lock or unlock it', 'Pay Period History / Archived Timesheets']
  },
  {
    role: 'Superintendent',
    question: 'How does a Superintendent enter overhead time in My Time?',
    expected: ['General Foreman, Superintendent, Admin and Owner', 'Company Overhead']
  },
  {
    role: 'General Foreman',
    question: 'How does a General Foreman review a submitted Daily Report?',
    expected: ['assigned-crew scope', 'full Crew Time table']
  },
  {
    role: 'Foreman',
    question: 'Can a Foreman save a JSA with no service?',
    expected: ['Offline JSA Mode', 'not Daily Reports']
  },
  {
    role: 'Foreman',
    question: 'How do I check Remaining Units left at a work point?',
    expected: ['searches by Work Point', 'Redlines stay separate']
  }
];

for (const scenario of scenarios) {
  const answer = answerFor(scenario.question);
  if (!answer) {
    failures.push(`${scenario.role} fallback scenario returned no answer: ${scenario.question}`);
    continue;
  }
  for (const expected of scenario.expected) {
    if (!answer.includes(expected)) {
      failures.push(`${scenario.role} fallback scenario is missing ${expected}: ${scenario.question}`);
    }
  }
}

for (const safetyMarker of [
  'the current offline workflow is JSA-only',
  'never promise a phone notification when the app is closed',
  'never claim that a specific role video exists unless the Training Center shows it'
]) {
  requireText(assistant, safetyMarker, 'Live-AI unsupported-feature boundary');
}

if (failures.length) {
  console.error('LineCrew Assistant knowledge validation failed:');
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log('LineCrew Assistant knowledge validation passed.');
console.log(`- ${promptRoleChecks.length} live-AI role models verified`);
console.log(`- ${scenarios.length} role-specific fallback questions verified`);
console.log('- Offline, notification and training boundaries verified');
