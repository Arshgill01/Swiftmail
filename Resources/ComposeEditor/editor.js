// Swiftmail compose editor. Runs as an app script in its own content world; the page
// itself allows no scripts at all (see the CSP in editor.html).
(function () {
  'use strict';
  const editor = document.getElementById('editor');
  const post = (name, value) => { try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) {} };

  const allowedTags = new Set(['B', 'STRONG', 'I', 'EM', 'U', 'A', 'P', 'DIV', 'BR', 'UL', 'OL', 'LI', 'BLOCKQUOTE', 'IMG', 'SPAN', 'H1', 'H2', 'H3', 'PRE', 'CODE']);
  const safeHref = (href) => /^(https?:|mailto:)/i.test((href || '').trim());

  // Pasted HTML keeps structure and basic formatting, never foreign fonts, colors or Word markup.
  function clean(html) {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const walk = (node) => {
      for (const child of Array.from(node.childNodes)) {
        if (child.nodeType === Node.COMMENT_NODE) { child.remove(); continue; }
        if (child.nodeType !== Node.ELEMENT_NODE) { continue; }
        walk(child);
        if (!allowedTags.has(child.tagName)) {
          if (['SCRIPT', 'STYLE', 'META', 'LINK', 'TITLE', 'XML', 'O:P'].includes(child.tagName) || child.tagName.includes(':')) {
            child.remove();
          } else {
            child.replaceWith(...Array.from(child.childNodes));
          }
          continue;
        }
        for (const attribute of Array.from(child.attributes)) {
          const keep = (child.tagName === 'A' && attribute.name === 'href' && safeHref(attribute.value))
            || (child.tagName === 'IMG' && attribute.name === 'src' && /^data:image\//i.test(attribute.value))
            || (child.tagName === 'IMG' && attribute.name === 'alt');
          if (!keep) { child.removeAttribute(attribute.name); }
        }
        if (child.tagName === 'IMG' && !child.getAttribute('src')) { child.remove(); }
      }
    };
    walk(doc.body);
    return doc.body.innerHTML;
  }

  let changeTimer = null;
  const changed = () => {
    clearTimeout(changeTimer);
    changeTimer = setTimeout(() => post('changed', editor.innerHTML), 250);
  };

  const insertImageFile = (file) => {
    const reader = new FileReader();
    reader.onload = () => {
      document.execCommand('insertHTML', false, '<img src="' + reader.result + '" alt="' + (file.name || 'image').replace(/"/g, '') + '">');
      changed();
    };
    reader.readAsDataURL(file);
  };

  editor.addEventListener('input', changed);
  editor.addEventListener('paste', (event) => {
    const data = event.clipboardData;
    if (!data) { return; }
    const images = Array.from(data.files || []).filter((file) => file.type.startsWith('image/'));
    if (images.length) {
      event.preventDefault();
      images.forEach(insertImageFile);
      return;
    }
    const html = data.getData('text/html');
    event.preventDefault();
    if (html) {
      document.execCommand('insertHTML', false, clean(html));
    } else {
      document.execCommand('insertText', false, data.getData('text/plain'));
    }
    changed();
  });
  editor.addEventListener('keydown', (event) => {
    if (!event.metaKey || event.altKey || event.ctrlKey) { return; }
    const key = event.key.toLowerCase();
    if (key === 'b' || key === 'i' || key === 'u') {
      event.preventDefault();
      document.execCommand(key === 'b' ? 'bold' : key === 'i' ? 'italic' : 'underline');
      changed();
      post('selection', SM.state());
    } else if (key === 'k') {
      event.preventDefault();
      post('link', window.getSelection().toString());
    }
  });
  document.addEventListener('selectionchange', () => post('selection', SM.state()));

  let savedRange = null;
  const saveSelection = () => {
    const selection = window.getSelection();
    if (selection.rangeCount && editor.contains(selection.anchorNode)) { savedRange = selection.getRangeAt(0).cloneRange(); }
  };
  const restoreSelection = () => {
    editor.focus();
    if (savedRange) {
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(savedRange);
    }
  };
  editor.addEventListener('blur', saveSelection);

  window.SM = {
    setContent(html) { editor.innerHTML = html; },
    getContent() { return editor.innerHTML; },
    focus(atStart) {
      editor.focus();
      if (atStart) {
        const range = document.createRange();
        range.setStart(editor, 0);
        range.collapse(true);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }
    },
    exec(command, value) {
      restoreSelection();
      if (command === 'createLink') {
        if (!safeHref(value)) { return; }
        if (window.getSelection().isCollapsed) {
          document.execCommand('insertHTML', false, '<a href="' + value.replace(/"/g, '%22') + '">' + value.replace(/</g, '&lt;') + '</a>');
        } else {
          document.execCommand('createLink', false, value);
        }
      } else if (command === 'blockquote') {
        document.execCommand('formatBlock', false, 'blockquote');
      } else {
        document.execCommand(command, false, value || null);
      }
      changed();
      post('selection', SM.state());
    },
    insertImage(dataURL, name) {
      restoreSelection();
      document.execCommand('insertHTML', false, '<img src="' + dataURL + '" alt="' + (name || 'image').replace(/"/g, '') + '">');
      changed();
    },
    // Switching the From alias swaps the signature.
    setSignature(html) {
      let signature = editor.querySelector('.gmail_signature');
      let prefix = editor.querySelector('.gmail_signature_prefix');
      if (!html) {
        if (signature) { signature.remove(); }
        if (prefix) { prefix.remove(); }
      } else if (signature) {
        signature.innerHTML = html;
      } else {
        const quote = editor.querySelector('.gmail_quote');
        const block = document.createElement('div');
        block.innerHTML = '<div dir="ltr" class="gmail_signature_prefix">-- </div><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature"></div>';
        block.querySelector('.gmail_signature').innerHTML = html;
        const nodes = Array.from(block.childNodes);
        if (quote) { nodes.forEach((node) => quote.parentNode.insertBefore(node, quote)); } else { nodes.forEach((node) => editor.appendChild(node)); }
      }
      changed();
    },
    state() {
      return {
        bold: document.queryCommandState('bold'),
        italic: document.queryCommandState('italic'),
        underline: document.queryCommandState('underline'),
      };
    },
  };
  post('ready', true);
})();
