// elm-e2e-dom.js — the smallest `document` that lets a static Elm program (`main = Html.text ...`,
// elm/virtual-dom's _VirtualDom_init) start on node, for run-elm-e2e.js. The tests print with
// Debug.log; the rendered view is built and then ignored, as the native harness ignores it.
// install() defines the global `document` (it must run before the program is required:
// elm/virtual-dom reads `document` once, at load) and returns the node to mount on.
'use strict';

class Node {
    constructor(nodeName) {
        this.nodeName = nodeName;
        this.childNodes = [];
        this.parentNode = null;
        this.attributes = {};
        this.style = {};
    }
    appendChild(child) {
        if (child.parentNode) child.parentNode.removeChild(child);
        child.parentNode = this;
        this.childNodes.push(child);
        return child;
    }
    insertBefore(child, ref) {
        if (!ref) return this.appendChild(child);
        if (child.parentNode) child.parentNode.removeChild(child);
        child.parentNode = this;
        this.childNodes.splice(this.childNodes.indexOf(ref), 0, child);
        return child;
    }
    removeChild(child) {
        const i = this.childNodes.indexOf(child);
        if (i >= 0) this.childNodes.splice(i, 1);
        child.parentNode = null;
        return child;
    }
    replaceChild(child, old) {
        this.insertBefore(child, old);
        return this.removeChild(old);
    }
    get firstChild() { return this.childNodes[0] || null; }
    get lastChild() { return this.childNodes[this.childNodes.length - 1] || null; }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    setAttributeNS(ns, key, value) { this.attributes[key] = String(value); }
    removeAttribute(key) { delete this.attributes[key]; }
    removeAttributeNS(ns, key) { delete this.attributes[key]; }
    getAttribute(key) { return key in this.attributes ? this.attributes[key] : null; }
    addEventListener() {}
    removeEventListener() {}
}

function install() {
    const document = {
        createElement: (tag) => new Node(tag.toUpperCase()),
        createElementNS: (ns, tag) => new Node(tag),
        createTextNode: (text) => Object.assign(new Node('#text'), { data: String(text) }),
        createDocumentFragment: () => new Node('#document-fragment'),
    };
    document.body = document.createElement('body');
    global.document = document;
    return document.body.appendChild(document.createElement('div'));
}

module.exports = { install };
