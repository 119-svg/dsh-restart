/**
 * @119-svg/dsh-restart · 客户端半区
 *
 * 在侧边栏底部（设置旁边）加一个 ⏻ 按钮：点一下 = 完全关闭并重新打开 DSH Desktop，
 * 与「托盘退出后重新打开」效果一致。按钮只负责调用宿主接口，真正的重启在宿主半区 + PowerShell 脚本里。
 */
window.__ModuleLoader__.load({
  id: '@119-svg/dsh-restart',
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    const react = require('react');
    const h = react.createElement;

    const API = '/api/dsh-restart';
    const PANEL = 'dsh-restart';
    // 客户端服务名：slots 来自 @deepseek-ai/dsh-client-ui-slots，layout 来自 ...-ui-layout
    const inject = ['slots', 'layout'];

    const CSS = `
.dshr-btn{display:inline-flex;align-items:center;justify-content:center;min-width:26px;height:26px;padding:0 6px;border:0;border-radius:8px;background:transparent;color:inherit;font:inherit;font-size:14px;line-height:1;cursor:pointer;opacity:.72;transition:opacity .15s,background .15s}
.dshr-btn:hover{opacity:1;background:var(--dsw-alias-interactive-bg-hover,rgba(38,49,72,.06))}
.dshr-btn[disabled]{opacity:.5;cursor:default}
`;

    let cssInjected = false;
    function ensureCss() {
      if (cssInjected || document.querySelector('style[data-dsh-restart]')) { cssInjected = true; return; }
      const style = document.createElement('style');
      style.setAttribute('data-dsh-restart', '1');
      style.textContent = CSS;
      document.head.appendChild(style);
      cssInjected = true;
    }

    async function call(action, body) {
      const res = await fetch(`${API}/${action}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body ?? {}),
      });
      let data;
      try { data = await res.json(); } catch { throw new Error(`接口返回异常（HTTP ${res.status}）`); }
      if (!data || data.ok !== true) throw new Error((data && data.error) || `请求失败（HTTP ${res.status}）`);
      return data.value;
    }

    function apply(ctx) {
      ensureCss();

      ctx.slots.inject('sidebar.footer.action', () => ctx.slots.register({
        name: 'sidebar.footer.action',
        id: `${PANEL}-button`,
        order: 92,
        label: () => '重启 DSH',
      }, () => h('button', {
        type: 'button',
        className: 'dshr-btn',
        title: '重启 DSH —— 完全关闭并重新打开（等同托盘退出后重开）。会中断当前对话与正在跑的任务',
        'aria-label': '重启 DSH',
        onClick: async (event) => {
          const button = event.currentTarget;
          if (!window.confirm('将完全关闭并重新打开 DSH Desktop（等同托盘退出后重开）。\n当前对话与正在跑的任务会中断，确定继续？')) return;
          button.disabled = true;
          button.textContent = '⏻ 重启中';
          try {
            await call('restartApp');
            button.textContent = '⏻ 已发出';
          } catch (error) {
            button.textContent = '⏻';
            window.alert('重启失败：' + error.message);
          } finally {
            window.setTimeout(() => {
              button.disabled = false;
              button.textContent = '⏻';
            }, 2000);
          }
        },
      }, '⏻')));
    }

    exports.apply = apply;
    exports.inject = inject;
    exports.name = 'dsh-restart';
    return module.exports;
  },
});
