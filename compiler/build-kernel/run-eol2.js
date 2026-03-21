// Run elm-optimize-level-2 transforms on a pre-compiled JS file
// with fine-grained control over which transforms to enable.
const fs = require('fs');
const path = require('path');

const inputFile = process.argv[2] || 'bin/eco-boot-2.js';
const outputFile = process.argv[3] || 'bin/eco-boot-2-eol2.js';
const mode = process.argv[4] || 'safe'; // 'safe', 'o2', 'o3'

// Find elm-optimize-level-2 package
const eol2Path = require.resolve('elm-optimize-level-2/dist/transform');
const Transform = require(eol2Path.replace('/transform', '/transform'));
const Types = require(eol2Path.replace('/transform', '/types'));

const jsSource = fs.readFileSync(inputFile, 'utf8');

// Safe transforms: only those that don't replace kernel functions
const safeTransforms = {
    replaceVDomNode: false,
    variantShapes: true,
    inlineNumberToString: false,
    inlineEquality: true,
    inlineFunctions: true,
    listLiterals: false,
    passUnwrappedFunctions: false,  // DISABLED: crashes with Eco kernel functions
    arrowFns: false,
    shorthandObjectLiterals: false,
    objectUpdate: false,
    unusedValues: false,
    replaceListFunctions: false,    // DISABLED: may conflict with Eco kernels
    replaceStringFunctions: false,
    recordUpdates: false,
    v8Analysis: false,
    fastCurriedFns: true,
    replacements: null
};

// O3 adds recordUpdates
const o3Transforms = { ...safeTransforms, recordUpdates: true };

const transforms = mode === 'o3' ? o3Transforms : safeTransforms;

console.log(`Applying transforms (mode=${mode}):`);
for (const [k, v] of Object.entries(transforms)) {
    if (v && k !== 'replacements') console.log(`  ${k}`);
}

Transform.transform(process.cwd(), jsSource, null, false, transforms)
    .then(result => {
        fs.writeFileSync(outputFile, result, 'utf8');
        console.log(`\n${inputFile} ───> ${outputFile}`);
        console.log(`Input: ${(jsSource.length / 1024 / 1024).toFixed(1)} MB`);
        console.log(`Output: ${(result.length / 1024 / 1024).toFixed(1)} MB`);
    })
    .catch(err => {
        console.error('Transform failed:', err);
        process.exit(1);
    });
