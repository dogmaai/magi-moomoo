import { pathToFileURL } from 'node:url';

const mockUrl = pathToFileURL('./test/bigquery-mock.mjs').href;

export function resolve(specifier, context, nextResolve) {
  if (specifier === '@google-cloud/bigquery') {
    return { url: mockUrl, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
