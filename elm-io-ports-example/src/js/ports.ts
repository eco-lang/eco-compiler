export function checkPortsExist(app: any, portNames: string[]) {
    if (!app.ports) {
        throw "The Elm application has no ports.";
    }

    const allPorts = `[${Object.keys(app.ports).sort().join(', ')}]`;

    for (let i = 0; i < portNames.length; i++) {
        const portName = portNames[i];

        // eslint-disable-next-line no-prototype-builtins
        if (!app.ports.hasOwnProperty(portName)) {
            throw new Error(`Could not find a port named ${portName} among: ${allPorts}`);
        }
    }
}
