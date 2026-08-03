import { register } from 'node:module';
import { pathToFileURL } from 'node:url';

register(pathToFileURL('./test/loader.mjs'), import.meta.url);
