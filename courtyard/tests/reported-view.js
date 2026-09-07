'use strict';

// Input boundary for isolated render fixtures, not a production replay format.
// Preserve the reported float32 camera values; never silently normalize a bad
// basis or change graphics to make a report fit the benchmark.
const fs = require('node:fs');
const BASIS_TOLERANCE = 1e-5;

function requireValue(ok, field, expectation) {
  if (!ok) throw new TypeError(`Reported view: ${field} ${expectation}`);
}

function object(value, field) {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value), field, 'must be an object');
  return value;
}

function finite(value, field) {
  requireValue(typeof value === 'number' && Number.isFinite(value), field, 'must be a finite number');
  return value;
}

function vector(value, length, field) {
  requireValue(Array.isArray(value) && value.length === length, field, `must contain ${length} numbers`);
  return Array.from(value, (number, index) => finite(number, `${field}[${index}]`));
}

function dimensions(value, field, maxWidth) {
  const result = vector(value, 2, field);
  for (const [index, maximum] of [[0, maxWidth], [1, 2160]]) {
    requireValue(Number.isInteger(result[index]) && result[index] >= 2 && result[index] <= maximum,
      `${field}[${index}]`, `must be an integer in 2..${maximum}`);
  }
  return result;
}

function parseReport(input) {
  object(input, 'report');
  const sourceCamera = object(input.camera, 'camera');
  const position_xyz = vector(sourceCamera.position_xyz, 3, 'camera.position_xyz');
  requireValue(Array.isArray(sourceCamera.basis) && sourceCamera.basis.length === 3,
    'camera.basis', 'must contain three basis columns');
  const basis = Array.from(sourceCamera.basis, (column, index) => vector(column, 3, `camera.basis[${index}]`));
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  for (let column = 0; column < 3; column++) {
    requireValue(Math.abs(dot(basis[column], basis[column]) - 1) <= BASIS_TOLERANCE,
      `camera.basis[${column}]`, 'must have unit length');
    for (let other = 0; other < column; other++) {
      requireValue(Math.abs(dot(basis[column], basis[other])) <= BASIS_TOLERANCE,
        'camera.basis', 'must be orthogonal');
    }
  }
  const [x, y, z] = basis;
  const determinant = x[0] * (y[1] * z[2] - y[2] * z[1]) -
    y[0] * (x[1] * z[2] - x[2] * z[1]) + z[0] * (x[1] * y[2] - x[2] * y[1]);
  requireValue(determinant > 0 && Math.abs(determinant - 1) <= 3 * BASIS_TOLERANCE,
    'camera.basis', 'must be right-handed');
  const fov_degrees = finite(sourceCamera.fov_degrees, 'camera.fov_degrees');
  requireValue(fov_degrees >= 1 && fov_degrees <= 179, 'camera.fov_degrees', 'must be in 1..179');
  const near = finite(sourceCamera.near, 'camera.near');
  const far = finite(sourceCamera.far, 'camera.far');
  requireValue(near > 0 && near < far, 'camera.near/far', 'must satisfy 0 < near < far');
  const keep_aspect = sourceCamera.keep_aspect;
  requireValue(keep_aspect === 0 || keep_aspect === 1, 'camera.keep_aspect', 'must be 0 or 1');

  const sourceRender = object(input.render, 'render');
  requireValue(sourceRender.quality === 'High', 'render.quality', 'must be High');
  requireValue(sourceRender.ssao === true, 'render.ssao', 'must be true');
  requireValue(sourceRender.scale_3d === 1, 'render.scale_3d', 'must be 1');
  const viewport = dimensions(sourceRender.viewport, 'render.viewport', 4096);
  const viewport_pixels = dimensions(sourceRender.viewport_pixels, 'render.viewport_pixels', 3840);
  const render_3d = dimensions(sourceRender.render_3d, 'render.render_3d', 3840);
  requireValue(render_3d.every((size, index) => size === viewport_pixels[index]),
    'render.render_3d', 'must equal render.viewport_pixels');
  requireValue(viewport_pixels.every((size, index) => size <= viewport[index]),
    'render.viewport_pixels', 'must fit inside the physical viewport');

  const sourceOperators = object(input.operators, 'operators');
  const operators = {};
  for (const name of ['alive', 'dead', 'sleeping']) {
    const value = sourceOperators[name];
    requireValue(Number.isInteger(value) && value >= 0 && value <= 9,
      `operators.${name}`, 'must be an integer in 0..9');
    operators[name] = value;
  }
  requireValue(operators.alive + operators.dead === 9, 'operators', 'must describe exactly nine bots');
  requireValue(operators.sleeping === operators.dead, 'operators.sleeping', 'must equal operators.dead');
  requireValue(typeof input.build === 'string' && input.build.trim().length > 0 && input.build.length <= 128 &&
    !/[\x00-\x1f\x7f]/.test(input.build), 'build', 'must be a nonempty single-line string of at most 128 characters');

  return {
    camera: {position_xyz, basis, fov_degrees, near, far, keep_aspect},
    render: {quality: 'High', ssao: true, scale_3d: 1, viewport, viewport_pixels, render_3d},
    operators,
    build: input.build,
  };
}

function loadReport(filename) {
  return parseReport(JSON.parse(fs.readFileSync(filename, 'utf8')));
}

module.exports = {parseReport, loadReport};
