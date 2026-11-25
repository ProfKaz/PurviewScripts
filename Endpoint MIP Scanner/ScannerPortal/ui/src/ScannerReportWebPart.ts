import * as React from 'react';
import { createRoot, Root } from 'react-dom/client';
import { SPHttpClient } from '@microsoft/sp-http';
import { BaseClientSideWebPart } from '@microsoft/sp-webpart-base';
import { IPropertyPaneConfiguration, PropertyPaneTextField } from '@microsoft/sp-property-pane';
import { Dropdown, IDropdownOption, Pivot, PivotItem } from '@fluentui/react';
import { parseAcceptanceIds, parseReport, Report } from './report';
import { ReportView } from './ReportView';
import { AgentSettings } from './AgentSettings';
import { AgentConfigStore } from './agentConfig';
import { RunAudit } from './RunAudit';
import { ConfigurationView } from './ConfigurationView';
import { ConsolidatedView, Cycle } from './ConsolidatedView';
import styles from './ReportView.module.scss';
import { Overview, Snapshot } from './Overview';

interface ReportProperties {
  acceptanceListId: string;
  acceptanceItemId: string;
  historyItemIds?: string;
  publishedProfilePath?: string;
}

const date = new Intl.DateTimeFormat('en-US', { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });

export default class ScannerReportWebPart extends BaseClientSideWebPart<ReportProperties> {
  private root?: Root;
  private agents?: AgentConfigStore;
  private request = 0;
  private configuration = 0;
  private options: IDropdownOption[] = [];
  private selection = 0;
  private report?: Report;
  private error?: string;

  public render(): void {
    this.root ??= createRoot(this.domElement);
    this.agents = new AgentConfigStore(this.context.spHttpClient, this.context.pageContext.web.absoluteUrl, this.context.pageContext.web.serverRelativeUrl, this.properties.acceptanceListId);
    const configuration = ++this.configuration;
    this.request++;
    this.options = [];
    this.selection = 0;
    this.report = undefined;
    this.error = undefined;

    const listId = (this.properties.acceptanceListId || '').trim();
    try {
      if (!/^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(listId)) {
        throw new Error('Set the acceptance list GUID in the web part properties.');
      }

      const ids = parseAcceptanceIds(this.properties.acceptanceItemId || '', this.properties.historyItemIds || '');
      this.options = ids.map(id => ({ key: id, text: 'Acceptance #' + id }));
      if (ids.length > 1) void this.loadHistoryLabels(listId, ids, configuration);
      this.select(listId, ids[0]);
    } catch (error) {
      this.error = error instanceof Error ? error.message : 'Invalid report configuration.';
      this.renderView(listId);
    }
  }

  private renderView(listId: string): void {
    const selector = this.options.length > 1
      ? React.createElement(Dropdown, {
          label: 'Accepted batch', options: this.options, selectedKey: this.selection,
          onChange: (_, option) => { if (option) this.select(listId, Number(option.key)); }
        })
      : null;
    const report = React.createElement(React.Fragment, null, selector,
      React.createElement(ReportView, { report: this.report, error: this.error, key: this.request }));
    const path = this.properties.publishedProfilePath?.trim();
    this.root?.render(React.createElement(React.Fragment, null,
        React.createElement(Pivot, { 'aria-label': 'Scanner Portal' },
          React.createElement(PivotItem, { headerText: 'Overview' }, React.createElement(Overview, { load: this.loadOverview })),
          React.createElement(PivotItem, { headerText: 'Batch detail' }, report),
          React.createElement(PivotItem, { headerText: 'Run audit' }, React.createElement(RunAudit, {
            client:this.context.spHttpClient, web:this.context.pageContext.web.absoluteUrl, ledger:listId
          })),
          React.createElement(PivotItem, { headerText: 'Consolidated inventory' },
            React.createElement(ConsolidatedView, { key: listId, load: this.loadCycles })),
          this.agents && React.createElement(PivotItem, { headerText: 'Agent management' }, React.createElement(AgentSettings, {store: this.agents})),
          path && React.createElement(PivotItem, { headerText: 'Configuration' },
            React.createElement(ConfigurationView, { key: path, path, load: this.loadProfile }))),
        React.createElement('footer', { className: styles.brand },
          'Powered by KazDemos',
          React.createElement('span', null, 'Web part v' + this.manifest.version))));
  }

  private readonly loadOverview = async (): Promise<Snapshot> => {
    const web = this.context.pageContext.web;
    const path = web.serverRelativeUrl.replace(/\/$/, '') + '/ScannerPortalExecutive/overview.json';
    const url = web.absoluteUrl + "/_api/web/GetFileByServerRelativePath(decodedurl=@path)/$value?@path=" + encodeURIComponent("'" + path.replace(/'/g, "''") + "'");
    const response = await this.context.spHttpClient.get(url, SPHttpClient.configurations.v1, { headers: { 'Cache-Control': 'no-cache' } });
    if (!response.ok) {
      const error = new Error('The governance snapshot is unavailable. Check publication and read access.');
      if ([401, 403, 404].indexOf(response.status) >= 0) error.name = 'AccessDenied';
      throw error;
    }
    const snapshot = await response.json() as Snapshot;
    if (snapshot.schema !== 1 || !Array.isArray(snapshot.groups)) throw new Error('Unsupported governance snapshot.');
    return snapshot;
  };

  private readonly loadCycles = async (): Promise<Cycle[]> => {
    const id = (this.properties.acceptanceListId || '').trim();
    if (!/^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(id)) throw new Error('Invalid list.');
    const url = this.context.pageContext.web.absoluteUrl + "/_api/web/lists(guid'" + id +
      "')/items?$select=Id,ReportingDeviceId,Title,BatchId,ManifestSha256,PortalReportJson&$orderby=Id desc&$top=50";
    const response = await this.context.spHttpClient.get(url, SPHttpClient.configurations.v1);
    if (!response.ok) throw new Error('Cannot read reports.');
    const data = await response.json() as { value: (Parameters<typeof parseReport>[0] & { Id: number; ReportingDeviceId: string })[] };
    const rows: Cycle[] = [];
    const seen = new Set<string>();
    for (const item of data.value) {
      if (!item.PortalReportJson) continue;
      const report = parseReport(item);
      if (!report.ManagedInventory) continue;
      const device = (item.ReportingDeviceId || '').toLowerCase();
      const key = device + '/' + report.BatchId.toLowerCase();
      if (!device || seen.has(key)) throw new Error('Ambiguous cycle identity.');
      seen.add(key);
      rows.push({ id: item.Id, device, report });
    }
    return rows;
  };

  private readonly loadProfile = async (path: string): Promise<ArrayBuffer> => {
    const web = this.context.pageContext.web;
    const serverPath = web.serverRelativeUrl.replace(/\/$/, '') + '/ScannerPortalConfig/' + path;
    const url = web.absoluteUrl + "/_api/web/GetFileByServerRelativePath(decodedurl=@path)/$value?@path=" +
      encodeURIComponent("'" + serverPath.replace(/'/g, "''") + "'");
    const response = await this.context.spHttpClient.get(url, SPHttpClient.configurations.v1);
    if (!response.ok) throw new Error([401, 403, 404].indexOf(response.status) !== -1
      ? 'This profile is unavailable or your account does not have access.'
      : 'Could not load the published profile. Try again.');
    return response.arrayBuffer();
  };

  private select(listId: string, itemId: number): void {
    this.selection = itemId;
    this.report = undefined;
    this.error = undefined;
    const request = ++this.request;
    this.renderView(listId);
    void this.load(listId, itemId, request);
  }

  private async read(listId: string, itemId: number, fields: string): Promise<unknown> {
    const web = this.context.pageContext.web.absoluteUrl;
    const url = web + "/_api/web/lists(guid'" + listId + "')/items(" + itemId + ')?$select=' + fields;
    const response = await this.context.spHttpClient.get(url, SPHttpClient.configurations.v1);
    if (!response.ok) {
      throw new Error([401, 403, 404].indexOf(response.status) !== -1
        ? 'This batch is unavailable or your account does not have access.'
        : 'Could not load the report. Try again.');
    }
    return response.json();
  }

  private async loadHistoryLabels(listId: string, ids: number[], configuration: number): Promise<void> {
    const options = await Promise.all(ids.map(async id => {
      const label = 'Acceptance #' + id;
      try {
        const item = await this.read(listId, id, 'Created,ReportingDeviceId') as { Created?: string; ReportingDeviceId?: string };
        const created = new Date(item.Created || '');
        const device = item.ReportingDeviceId;
        const parts = [label];
        if (Number.isFinite(created.getTime())) parts.push(date.format(created));
        if (device && /^[a-f\d-]{36}$/i.test(device)) parts.push('Device ' + device.slice(0, 8));
        return { key: id, text: parts.join(' · ') };
      } catch {
        return { key: id, text: label };
      }
    }));
    if (this.configuration === configuration) {
      this.options = options;
      this.renderView(listId);
    }
  }

  private async load(listId: string, itemId: number, request: number): Promise<void> {
    try {
      const item = await this.read(listId, itemId, 'Title,BatchId,ManifestSha256,PortalReportJson') as Parameters<typeof parseReport>[0];
      if (!item.PortalReportJson) throw new Error('This accepted batch does not have a saved report yet.');
      const report = parseReport(item);
      if (this.request !== request) return;
      this.report = report;
    } catch (error) {
      if (this.request !== request) return;
      this.error = error instanceof Error ? error.message : 'Could not load the report.';
    }
    this.renderView(listId);
  }

  protected onDispose(): void {
    this.request++;
    this.configuration++;
    this.root?.unmount();
    this.root = undefined;
  }

  protected getPropertyPaneConfiguration(): IPropertyPaneConfiguration {
    return { pages: [{ header: { description: 'Select accepted batches from the current site.' }, groups: [{
      groupName: 'Report source', groupFields: [
        PropertyPaneTextField('acceptanceListId', { label: 'ScannerPortalAcceptance list GUID' }),
        PropertyPaneTextField('acceptanceItemId', { label: 'Acceptance item ID' }),
        PropertyPaneTextField('historyItemIds', { label: 'Additional acceptance item IDs', description: 'Comma-separated IDs. Configure up to ten items including the default.' })
      ]
    }, {
      groupName: 'Configuration preview', groupFields: [
        PropertyPaneTextField('publishedProfilePath', {
          label: 'Published profile path',
          description: 'Path relative to ScannerPortalConfig. Leave blank to hide Configuration.'
        })
      ]
    }] }] };
  }
}
