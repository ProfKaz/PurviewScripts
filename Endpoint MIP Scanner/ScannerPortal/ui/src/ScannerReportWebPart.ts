import * as React from 'react';
import { createRoot, Root } from 'react-dom/client';
import { SPHttpClient } from '@microsoft/sp-http';
import { BaseClientSideWebPart } from '@microsoft/sp-webpart-base';
import { IPropertyPaneConfiguration, PropertyPaneTextField } from '@microsoft/sp-property-pane';
import { parseReport } from './report';
import { ReportView } from './ReportView';

interface ReportProperties {
  acceptanceListId: string;
  acceptanceItemId: string;
}

export default class ScannerReportWebPart extends BaseClientSideWebPart<ReportProperties> {
  private root?: Root;
  private request = 0;

  public render(): void {
    this.root ??= createRoot(this.domElement);
    const request = ++this.request;
    const listId = (this.properties.acceptanceListId || '').trim();
    const itemId = Number(this.properties.acceptanceItemId);
    if (!/^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(listId) ||
        !Number.isInteger(itemId) || itemId < 1 || itemId > 2147483647) {
      this.root.render(React.createElement(ReportView, { error: 'Configura la lista de aceptaciones y el ID del lote en las propiedades.' }));
      return;
    }
    this.root.render(React.createElement(ReportView, { key: request }));
    void this.load(listId, itemId, request);
  }

  private async load(listId: string, itemId: number, request: number): Promise<void> {
    try {
      const web = this.context.pageContext.web.absoluteUrl;
      const url = web + "/_api/web/lists(guid'" + listId + "')/items(" + itemId + ')?$select=Title,BatchId,ManifestSha256,PortalReportJson';
      const response = await this.context.spHttpClient.get(url, SPHttpClient.configurations.v1);
      if (!response.ok) {
        throw new Error([401, 403, 404].indexOf(response.status) !== -1
          ? 'El lote no está disponible o tu cuenta no tiene acceso.'
          : 'No se pudo cargar el reporte. Vuelve a intentar.');
      }
      const item = await response.json();
      const report = parseReport(item);
      if (this.request === request) this.root?.render(React.createElement(ReportView, { report, key: request }));
    } catch (error) {
      const message = error instanceof Error ? error.message : 'No se pudo cargar el reporte.';
      if (this.request === request) this.root?.render(React.createElement(ReportView, { error: message, key: request }));
    }
  }

  protected onDispose(): void {
    this.request++;
    this.root?.unmount();
    this.root = undefined;
  }

  protected getPropertyPaneConfiguration(): IPropertyPaneConfiguration {
    return { pages: [{ header: { description: 'Selecciona un lote aceptado del sitio actual.' }, groups: [{
      groupName: 'Origen del reporte', groupFields: [
        PropertyPaneTextField('acceptanceListId', { label: 'GUID de ScannerPortalAcceptance' }),
        PropertyPaneTextField('acceptanceItemId', { label: 'ID del registro de aceptación' })
      ]
    }] }] };
  }
}
