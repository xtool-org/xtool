#!/usr/bin/env node

import fs from 'fs';

function format(schema) {
    // this field is required when using the private Xcode API
    const capabilityCreateRelationships = schema.components.schemas.BundleIdCapabilityCreateRequest.properties.data.properties.relationships;
    capabilityCreateRelationships.properties.capability = {
        type: 'object',
        properties: {
            data: {
                type: 'object',
                properties: {
                    type: {
                        type: 'string',
                        enum: ['capabilities'],
                    },
                    id: { $ref: '#/components/schemas/CapabilityType' },
                },
                required: ['id', 'type'],
            },
        },
        required: ['data'],
    }
    capabilityCreateRelationships.required.push('capability');

    // we don't use this but it triggers a deprecation warning. see:
    // https://github.com/apple/swift-openapi-generator/issues/715
    schema.components.schemas.App.properties.relationships.properties.inAppPurchases.deprecated = false;

    return schema;
}

const text = fs.readFileSync(process.stdin.fd, 'utf8');
const json = JSON.parse(text);
const formatted = format(json);
const formattedText = JSON.stringify(formatted);
console.log(formattedText);
