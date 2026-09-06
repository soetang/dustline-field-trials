'use strict';

// Test-only source transform. No hook belongs in the normal project/export.
// Inclusive/self scope time includes engine calls made by these functions;
// neither number is a measurement of pure GDScript VM arithmetic.
const fs = require('node:fs');
const path = require('node:path');

const LABELS = Object.freeze([
  'game._physics_process', 'game._process', 'game.fire_shot',
  'bot._physics_process', 'bot.think', 'bot.see', 'bot._process',
  'layout.segment_clear', 'layout.path',
  'player._physics_process', 'player._process',
  'operator_rig.update_pose', 'operator_rig.flush', 'foot_placement.update',
  'weapon_clearance.resolve', 'hud._process', 'browser._process',
  'sound.play_at', 'objective._physics_process', 'spectator._physics_process',
  'hud._draw',
]);
const SPECIFICATION = Object.freeze(LABELS.map((label, id) => {
  const [script, name] = label.split('.');
  return Object.freeze({ id, label, file: `scripts/${script}.gd`, name });
}));
const MARKER = '# CPU_PROFILE_TEST_ONLY: generated in an isolated project copy';
const ORIGINAL_PREFIX = '_cpu_original_';

function fail(message) { throw new Error(`CPU instrumentation: ${message}`); }

// Retain positions/newlines while masking comments and quoted literals. This
// prevents fake declarations, commas or brackets inside strings from matching.
function codeMask(source) {
  const out = source.split('');
  let quote = null;
  for (let i = 0; i < source.length;) {
    if (quote) {
      if (source.startsWith(quote, i)) {
        for (let j = 0; j < quote.length; j++) out[i + j] = ' ';
        i += quote.length;
        quote = null;
      } else if (source[i] === '\\') {
        out[i++] = ' ';
        if (i < source.length) { if (source[i] !== '\n') out[i] = ' '; i++; }
      } else {
        if (source[i] === '\n' && quote.length === 1) fail('unterminated single-line string');
        if (source[i] !== '\n') out[i] = ' ';
        i++;
      }
    } else if (source[i] === '#') {
      while (i < source.length && source[i] !== '\n') out[i++] = ' ';
    } else if (source[i] === '"' || source[i] === "'") {
      quote = source.startsWith(source[i].repeat(3), i) ? source[i].repeat(3) : source[i];
      for (let j = 0; j < quote.length; j++) out[i + j] = ' ';
      i += quote.length;
    } else i++;
  }
  if (quote) fail('unterminated string');
  return out.join('');
}

function closingBracket(mask, start) {
  const pairs = { '(': ')', '[': ']', '{': '}' };
  const stack = [];
  for (let i = start; i < mask.length; i++) {
    const c = mask[i];
    if (pairs[c]) stack.push(pairs[c]);
    else if (')]}'.includes(c)) {
      if (stack.pop() !== c) fail('unbalanced signature brackets');
      if (!stack.length) return i;
    }
  }
  fail('unterminated signature');
}

function splitTopLevel(text, separator) {
  const parts = [];
  const stack = [];
  const pairs = { '(': ')', '[': ']', '{': '}' };
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (pairs[text[i]]) stack.push(pairs[text[i]]);
    else if (')]}'.includes(text[i])) {
      if (stack.pop() !== text[i]) fail('unbalanced parameter brackets');
    } else if (text[i] === separator && stack.length === 0) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  if (stack.length) fail('unterminated parameter brackets');
  parts.push(text.slice(start));
  return parts;
}

function validType(type) {
  type = type.replace(/\s/g, '');
  const match = /^([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)(.*)$/.exec(type);
  if (!match) return false;
  if (!match[2]) return true;
  const suffix = match[2];
  if (suffix[0] !== '[' || closingBracket(suffix, 0) !== suffix.length - 1) return false;
  const inner = splitTopLevel(suffix.slice(1, -1), ',');
  return inner.length > 0 && inner.every(part => part.length > 0 && validType(part));
}

function parameterNames(masked) {
  if (!masked.trim()) return [];
  const parts = splitTopLevel(masked, ',');
  if (!parts[parts.length - 1].trim()) parts.pop(); // GDScript trailing comma.
  const names = parts.map(part => {
    const match = /^\s*([A-Za-z_]\w*)\s*([\s\S]*)$/.exec(part);
    if (!match) fail(`unsupported parameter: ${part.trim()}`);
    const [, name, rest] = match;
    if (name === '_cpu_profile_result' || name === 'CpuProbe') fail(`reserved parameter: ${name}`);
    if (!rest || rest.startsWith('=') || /^:\s*=/.test(rest)) return name;
    if (!rest.startsWith(':')) fail(`unsupported parameter suffix for ${name}`);
    const typed = rest.slice(1);
    const equals = splitTopLevel(typed, '=');
    if (!validType(equals[0].trim())) fail(`unsupported parameter type for ${name}`);
    return name;
  });
  if (new Set(names).size !== names.length) fail('duplicate parameter names');
  return names;
}

function parseFunction(source, mask, declaration) {
  const open = mask.indexOf('(', declaration.index);
  const close = closingBracket(mask, open);
  let end = close + 1;
  while (/\s/.test(mask[end] || '') && end < mask.length) end++;
  if (mask.slice(end, end + 2) !== '->') fail(`${declaration.name} requires an explicit return type`);
  const returnStart = end + 2;
  end = returnStart;
  const stack = [];
  for (; end < mask.length; end++) {
    const c = mask[end];
    if (c === '[') stack.push(']');
    else if (c === ']') { if (stack.pop() !== ']') fail('unbalanced return type'); }
    else if (c === ':' && !stack.length) break;
  }
  if (end === mask.length) fail(`${declaration.name} has no signature terminator`);
  const returnType = mask.slice(returnStart, end).replace(/\s/g, '');
  if (!validType(returnType)) fail(`unsupported return type for ${declaration.name}`);
  const names = parameterNames(mask.slice(open + 1, close));
  // Await would time scheduling, not the suspended work, and implicit super()
  // would resolve against the newly renamed method. Neither is safe to wrap.
  let bodyEnd = source.indexOf('\n', end);
  if (bodyEnd < 0) bodyEnd = source.length;
  else {
    const following = /^[^\s#][^\n]*/gm;
    following.lastIndex = bodyEnd + 1;
    const next = following.exec(mask);
    bodyEnd = next ? next.index : source.length;
  }
  const body = mask.slice(end + 1, bodyEnd);
  if (/\bawait\b/.test(body)) fail(`async body unsupported: ${declaration.name}`);
  if (/\bsuper\s*\(/.test(body)) fail(`implicit super unsupported: ${declaration.name}`);
  const before = source.slice(0, declaration.index).trimEnd().split('\n').pop() || '';
  if (/^\s*@/.test(before)) fail(`annotated function unsupported: ${declaration.name}`);
  return { end: end + 1, names, returnType };
}

function instrumentSource(source, specification) {
  if (typeof source !== 'string' || !Array.isArray(specification) || !specification.length) fail('source and nonempty specification required');
  const mask = codeMask(source);
  if (source.includes(MARKER) || /\bCpuProbe\b|\b_cpu_original_\w*/.test(mask)) fail('already instrumented or reserved names present');
  const ids = new Set();
  const names = new Set();
  for (const spec of specification) {
    if (!Number.isInteger(spec.id) || spec.id < 0 || spec.id >= 32 || !/^[A-Za-z_]\w*$/.test(spec.name)) fail('invalid scope specification');
    if (ids.has(spec.id) || names.has(spec.name)) fail('duplicate scope specification');
    ids.add(spec.id); names.add(spec.name);
  }
  const declarations = [...mask.matchAll(/^(static[ \t]+)?func[ \t]+([A-Za-z_]\w*)[ \t]*\(/gm)]
    .map(match => ({ index: match.index, name: match[2], nameIndex: match.index + match[0].lastIndexOf(match[2]) }));
  const edits = [];
  for (const spec of specification) {
    const matches = declarations.filter(declaration => declaration.name === spec.name);
    if (matches.length !== 1) fail(`expected exactly one ${spec.name}, found ${matches.length}`);
    const declaration = matches[0];
    const parsed = parseFunction(source, mask, declaration);
    const signature = source.slice(declaration.index, parsed.end);
    const renamed = ORIGINAL_PREFIX + spec.name;
    const originalSignature = source.slice(declaration.index, declaration.nameIndex) + renamed + source.slice(declaration.nameIndex + spec.name.length, parsed.end);
    const call = `${renamed}(${parsed.names.join(', ')})`;
    const disabled = parsed.returnType === 'void' ? `\t\t${call}\n\t\treturn` : `\t\treturn ${call}`;
    const enabled = parsed.returnType === 'void'
      ? `\t${call}\n\tCpuProbe.end()\n\treturn`
      : `\tvar _cpu_profile_result: ${parsed.returnType} = ${call}\n\tCpuProbe.end()\n\treturn _cpu_profile_result`;
    edits.push({ start: declaration.index, end: parsed.end,
      text: `${signature}\n\tif not CpuProbe.enabled:\n${disabled}\n\tCpuProbe.begin(${spec.id})\n${enabled}\n\n${originalSignature}` });
  }
  const prologue = [...mask.matchAll(/^(?:extends|class_name)\b[^\n]*(?:\n|$)/gm)];
  if (prologue.filter(match => match[0].startsWith('extends')).length !== 1) fail('one top-level extends declaration required');
  const insertion = Math.max(...prologue.map(match => match.index + match[0].length));
  if (insertion > Math.min(...edits.map(edit => edit.start))) fail('unexpected script prologue order');
  edits.push({ start: insertion, end: insertion,
    text: `${source[insertion - 1] === '\n' ? '' : '\n'}\n${MARKER}\nconst CpuProbe = preload("res://_cpu_profile.gd")\n` });
  let result = source;
  for (const edit of edits.sort((a, b) => b.start - a.start)) result = result.slice(0, edit.start) + edit.text + result.slice(edit.end);
  return result;
}

function instrumentProject(projectDir) {
  const root = fs.realpathSync(projectDir);
  const normal = fs.realpathSync(path.resolve(__dirname, '..'));
  if (root === normal || root.startsWith(normal + path.sep) || normal.startsWith(root + path.sep)) fail('refusing the normal project or its ancestor/descendant');
  if (!fs.statSync(root).isDirectory() || !fs.existsSync(path.join(root, 'project.godot'))) fail('temporary Godot project required');
  if (!fs.existsSync(path.join(root, '_cpu_profile.gd'))) fail('copy the test collector to _cpu_profile.gd before instrumentation');
  const files = [...new Set(SPECIFICATION.map(spec => spec.file))];
  const prepared = files.map(file => {
    const target = path.join(root, file);
    const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || !fs.realpathSync(target).startsWith(root + path.sep)) fail(`unsafe copied source target: ${file}`);
    const source = fs.readFileSync(target, 'utf8');
    return { target, source: instrumentSource(source, SPECIFICATION.filter(spec => spec.file === file)) };
  });
  // Parse every selected signature before touching any file. Unsupported source
  // fails closed instead of leaving a partly instrumented benchmark project.
  for (const item of prepared) fs.writeFileSync(item.target, item.source);
  const mapping = SPECIFICATION.map(spec => ({ ...spec }));
  console.log('CPU_PROFILE_MAPPING', JSON.stringify(mapping));
  return { mapping, labels: [...LABELS], files };
}

module.exports = { LABELS, SPECIFICATION, instrumentSource, instrumentProject };
