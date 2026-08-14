# This file is part of IRI.
#
# Copyright (C) 2026 Nikita Karpukhin
#
# IRI is free software: you can redistribute it and/or modify it under the
# terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# IRI is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
# more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with IRI. If not, see <https://www.gnu.org/licenses/>.

defmodule Iri.Collections.StaticExport do
  @moduledoc "Builds a portable static website for one private collection."

  alias Iri.Library.{TaxonomyTerm, Title}
  alias Iri.Media

  @theme_order ~w(dark light vapor high-contrast ai-slop)
  @themes %{
    "dark" => %{
      label: "Dark",
      color: "#0f0e17",
      stylesheet:
        ":root{color-scheme:dark;--canvas:#0f0e17;--body-background:#0f0e17;--panel:#171621;--raised:#24232f;--border:#24232f;--border-strong:#343341;--text:#d7d7df;--muted:#a7a9be;--faint:#797b8d;--heading:#fffffe;--accent:#ff8906;--accent-text:#ffad54;--accent-soft:rgba(255,137,6,.12);--warning:#f25f4c;--button:#24232f;--button-hover:#343341;--button-text:#e9e9ee;--shadow:rgba(0,0,0,.28);--backdrop:rgba(15,14,23,.9);--radius-control:.25rem;--radius-card:.5rem;--radius-dialog:.5rem;--radius-pill:.25rem}"
    },
    "light" => %{
      label: "Light",
      color: "#eff0f3",
      stylesheet:
        ":root{color-scheme:light;--canvas:#eff0f3;--body-background:#eff0f3;--panel:#fffffe;--raised:#e3e4e9;--border:#d0d2da;--border-strong:#9599a4;--text:#2a2a2a;--muted:#6b7080;--faint:#6b7080;--heading:#0d0d0d;--accent:#ff8e3c;--accent-text:#7c3c08;--accent-soft:rgba(255,142,60,.14);--warning:#9a3412;--button:#fffffe;--button-hover:#e3e4e9;--button-text:#1c1c1c;--shadow:rgba(13,13,13,.13);--backdrop:rgba(13,13,13,.78);--radius-control:.25rem;--radius-card:.5rem;--radius-dialog:.5rem;--radius-pill:.25rem}"
    },
    "vapor" => %{
      label: "Vapor",
      color: "#3f4738",
      stylesheet:
        ":root{color-scheme:dark;--canvas:#3f4738;--body-background:#3f4738;--panel:#4c5844;--raised:#58654f;--border:#58654f;--border-strong:#76866b;--text:#d3dac9;--muted:#a2ad97;--faint:#8a977f;--heading:#eff6ee;--accent:#968732;--accent-text:#f0ecd4;--accent-soft:rgba(150,135,50,.16);--warning:#e2dbae;--button:linear-gradient(to bottom,#5f6d56,#58654f);--button-hover:linear-gradient(to bottom,#62715a,#5f6d56);--button-text:#f0ecd4;--shadow:rgba(20,24,17,.45);--backdrop:rgba(26,29,18,.9);--radius-control:0;--radius-card:0;--radius-dialog:0;--radius-pill:0}"
    },
    "high-contrast" => %{
      label: "High Contrast",
      color: "#000000",
      stylesheet:
        ":root{color-scheme:dark;--canvas:#000;--body-background:#000;--panel:#050505;--raised:#333;--border:#767676;--border-strong:#fff;--text:#fff;--muted:#e2e2e2;--faint:#c6c6c6;--heading:#fff;--accent:#ffe600;--accent-text:#fff36a;--accent-soft:rgba(255,230,0,.18);--warning:#fda4af;--button:#050505;--button-hover:#333;--button-text:#fff;--shadow:rgba(255,255,255,.18);--backdrop:rgba(0,0,0,.96);--radius-control:0;--radius-card:0;--radius-dialog:0;--radius-pill:0}"
    },
    "ai-slop" => %{
      label: "AI Slop",
      color: "#020617",
      stylesheet:
        ":root{color-scheme:dark;--canvas:#080d18;--body-background:radial-gradient(circle at top,#152238 0,#080d18 34rem);--panel:#0f172a;--raised:#1e293b;--border:#1e293b;--border-strong:#334155;--text:#e2e8f0;--muted:#94a3b8;--faint:#64748b;--heading:#fff;--accent:#5eead4;--accent-text:#99f6e4;--accent-soft:rgba(94,234,212,.1);--warning:#fbbf24;--button:#111b2d;--button-hover:#1e293b;--button-text:#cbd5e1;--shadow:rgba(0,0,0,.18);--backdrop:rgba(2,6,23,.88);--radius-control:.8rem;--radius-card:1rem;--radius-dialog:1rem;--radius-pill:999px}"
    }
  }

  @theme_stylesheets Enum.map_join(@theme_order, fn name ->
                       theme = Map.fetch!(@themes, name)

                       String.replace_prefix(
                         theme.stylesheet,
                         ":root",
                         ~s(html[data-theme="#{name}"])
                       )
                     end)

  @stylesheet """
  :root{color-scheme:dark;font-family:"Noto Sans",ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#080d18;color:#e2e8f0}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}*{box-sizing:border-box}body{margin:0;min-width:320px;background:radial-gradient(circle at top,#152238 0,#080d18 34rem);line-height:1.5}a{color:inherit}.shell{width:min(1120px,calc(100% - 2rem));margin:0 auto;padding:2rem 0 4rem}.eyebrow{margin:0;color:#5eead4;font-size:.72rem;font-weight:750;letter-spacing:.2em;text-transform:uppercase}.page-title{margin:.4rem 0 0;color:#fff;font-size:clamp(2rem,7vw,3.5rem);line-height:1.05}.muted{color:#94a3b8}.topbar{display:flex;align-items:flex-end;justify-content:space-between;gap:1.25rem;padding-bottom:1.5rem;border-bottom:1px solid #1e293b}.controls{display:grid;grid-template-columns:minmax(0,1fr) 12rem auto;gap:.75rem;margin:1.25rem 0}.control{min-height:2.8rem;border:1px solid #334155;border-radius:.8rem;background:#0f172a;color:#e2e8f0;padding:.7rem .85rem;font:inherit}.button{display:inline-flex;min-height:2.8rem;align-items:center;justify-content:center;gap:.45rem;border:1px solid #334155;border-radius:.8rem;background:#111b2d;color:#cbd5e1;padding:.65rem .9rem;font:inherit;font-weight:700;text-decoration:none;cursor:pointer}.button:hover{border-color:#64748b;color:#fff}.collection-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:1rem}.game-card{display:flex;min-width:0;flex-direction:column;overflow:hidden;border:1px solid #1e293b;border-radius:1rem;background:rgba(15,23,42,.82);box-shadow:0 16px 38px rgba(0,0,0,.18)}.game-card[hidden]{display:none}.cover{position:relative;display:block;aspect-ratio:3/4;overflow:hidden;background:linear-gradient(145deg,#1e293b,#0f172a)}.cover img{width:100%;height:100%;object-fit:cover}.cover-placeholder{display:grid;width:100%;height:100%;place-items:center;color:#64748b;font-size:3rem;font-weight:800}.card-body{display:flex;flex:1;flex-direction:column;padding:1rem}.game-title{margin:0;color:#fff;font-size:1rem;line-height:1.3}.game-title a{text-decoration:none}.game-title a:hover{color:#99f6e4}.metadata{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:.65rem}.chip{display:inline-flex;align-items:center;border-radius:999px;background:#1e293b;padding:.25rem .55rem;color:#cbd5e1;font-size:.72rem}.chip.rating{background:rgba(139,92,246,.14);color:#ddd6fe}.store-chip{border:1px solid #334155;text-decoration:none}.store-chip:hover{border-color:#5eead4;color:#99f6e4}.comment{margin:.85rem 0 0;padding:.75rem;border-left:2px solid #8b5cf6;background:rgba(139,92,246,.07);color:#cbd5e1;font-size:.84rem;white-space:pre-wrap}.detail-header{margin-bottom:1.4rem}.back-link{display:inline-flex;margin-bottom:1rem;color:#94a3b8;text-decoration:none}.back-link:hover{color:#fff}.hero{display:grid;grid-template-columns:minmax(190px,280px) minmax(0,1fr);gap:2rem;align-items:start}.hero-cover{overflow:hidden;border:1px solid #1e293b;border-radius:1rem;background:#0f172a;aspect-ratio:3/4}.hero-cover img{width:100%;height:100%;object-fit:cover}.detail-title{margin:0;color:#fff;font-size:clamp(2rem,6vw,3.75rem);line-height:1.02}.section{margin-top:1.4rem;padding-top:1.4rem;border-top:1px solid #1e293b}.section h2{margin:0 0 .75rem;color:#fff;font-size:1.15rem}.section p{margin:.55rem 0}.tag-list,.link-list{display:flex;flex-wrap:wrap;gap:.5rem}.store-link{display:inline-flex;align-items:center;border:1px solid #334155;border-radius:.7rem;padding:.5rem .7rem;color:#cbd5e1;text-decoration:none}.store-link:hover{border-color:#5eead4;color:#99f6e4}.screenshots{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.75rem}.screenshot{overflow:hidden;border:1px solid #1e293b;border-radius:.8rem;background:#0f172a;aspect-ratio:16/9}.screenshot img{width:100%;height:100%;object-fit:cover}.sensitive-reveal{display:block;width:100%;height:100%;padding:0;border:0;background:none;color:inherit;cursor:pointer}.sensitive{filter:blur(24px);transform:scale(1.08);cursor:pointer}.sensitive.revealed{filter:none;transform:none}.sensitive-note{color:#fbbf24;font-size:.78rem}.rating-face{width:1.15rem;height:1.15rem;vertical-align:-.22rem}.rating-face-wrap{position:relative;display:inline-block;width:1.15rem;height:1.15rem;vertical-align:-.22rem}.rating-face-wrap .rating-face{display:block;vertical-align:0}.rating-face-base{opacity:.3}.rating-face-half{position:absolute;inset:0 auto 0 0;width:50%;overflow:hidden}.rating-face-half .rating-face{width:2.3rem;max-width:none}.empty{padding:4rem 1rem;text-align:center;color:#64748b}.footer{margin-top:3rem;padding-top:1.2rem;border-top:1px solid #1e293b;color:#64748b;font-size:.78rem}@media(max-width:720px){.shell{width:min(100% - 1rem,1120px);padding-top:1rem}.topbar{align-items:start;flex-direction:column}.controls{grid-template-columns:1fr 1fr}.controls input{grid-column:1/-1}.collection-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:.6rem}.card-body{padding:.75rem}.hero{grid-template-columns:1fr}.hero-cover{width:min(70vw,260px)}.screenshots{grid-template-columns:1fr}}@media(prefers-reduced-motion:no-preference){.game-card,.button,.store-link{transition:border-color .15s,color .15s,transform .15s}.game-card:hover{transform:translateY(-2px)}}
  """

  @lightbox_stylesheet """
  .screenshot{padding:0;cursor:zoom-in}.lightbox{width:min(98vw,1600px);max-width:none;height:96vh;max-height:none;margin:auto;border:1px solid #334155;border-radius:1rem;background:#050914;padding:0;color:#e2e8f0;box-shadow:0 28px 80px rgba(0,0,0,.7)}.lightbox::backdrop{background:rgba(2,6,23,.88);backdrop-filter:blur(5px)}.lightbox-frame{position:relative;display:grid;width:100%;height:100%;place-items:center;padding:.5rem}.lightbox-image{display:block;width:100%;height:100%;object-fit:contain}.lightbox-control{position:absolute;z-index:1;display:grid;width:2.8rem;height:2.8rem;place-items:center;border:1px solid #475569;border-radius:999px;background:rgba(15,23,42,.9);color:#e2e8f0;font:inherit;font-size:1.35rem;cursor:pointer}.lightbox-control:hover{border-color:#94a3b8;background:#1e293b;color:#fff}.lightbox-control[hidden]{display:none}.lightbox-close{top:.75rem;right:.75rem}.lightbox-previous{left:.75rem;top:50%;transform:translateY(-50%)}.lightbox-next{right:.75rem;top:50%;transform:translateY(-50%)}@media(max-width:720px){.lightbox{width:100vw;height:100dvh;border:0;border-radius:0}.lightbox-frame{padding:3.75rem .75rem}.lightbox-previous{left:.5rem;bottom:.6rem;top:auto;transform:none}.lightbox-next{right:.5rem;bottom:.6rem;top:auto;transform:none}}
  """

  @theme_overrides """
  :root{background:var(--canvas);color:var(--text)}body{background:var(--body-background)}.eyebrow{color:var(--accent-text)}.page-title,.game-title,.detail-title,.section h2{color:var(--heading)}.muted,.back-link{color:var(--muted)}.topbar,.section,.footer{border-color:var(--border)}.control{border-color:var(--border-strong);border-radius:var(--radius-control);background:var(--panel);color:var(--text)}.button{border-color:var(--border-strong);border-radius:var(--radius-control);background:var(--button);color:var(--button-text);box-shadow:0 1px 2px var(--shadow)}.button:hover{border-color:var(--accent);background:var(--button-hover);color:var(--heading)}.game-card{border-color:var(--border);border-radius:var(--radius-card);background:var(--panel);box-shadow:0 12px 30px var(--shadow)}.cover{background:linear-gradient(145deg,var(--raised),var(--panel))}.cover-placeholder,.empty,.footer{color:var(--faint)}.game-title a:hover,.store-chip:hover,.store-link:hover{color:var(--accent-text)}.chip{border-radius:var(--radius-pill);background:var(--raised);color:var(--text)}.chip.rating{background:var(--accent-soft);color:var(--accent-text)}.store-chip,.store-link{border-color:var(--border-strong)}.store-chip:hover,.store-link:hover{border-color:var(--accent)}.comment{border-color:var(--accent);background:var(--accent-soft);color:var(--text)}.back-link:hover{color:var(--heading)}.hero-cover,.screenshot{border-color:var(--border);border-radius:var(--radius-card);background:var(--panel)}.store-link{border-radius:var(--radius-control);color:var(--text)}.sensitive-note{color:var(--warning)}.lightbox{border-color:var(--border-strong);border-radius:var(--radius-dialog);background:var(--canvas);color:var(--text);box-shadow:0 28px 80px var(--shadow)}.lightbox::backdrop{background:var(--backdrop)}.lightbox-control{border-color:var(--border-strong);border-radius:var(--radius-pill);background:var(--panel);color:var(--text)}.lightbox-control:hover{border-color:var(--accent);background:var(--raised);color:var(--heading)}:focus-visible{outline:2px solid var(--accent);outline-offset:2px}html[data-theme="vapor"] .button,html[data-theme="vapor"] .lightbox-control{border-color:#76866b #3f4738 #3f4738 #76866b;box-shadow:inset 0 1px 0 rgba(239,246,238,.1),0 1px 2px var(--shadow);text-shadow:0 1px rgba(20,24,17,.65)}html[data-theme="vapor"] .button:active,html[data-theme="vapor"] .lightbox-control:active{border-color:#3f4738 #76866b #76866b #3f4738;box-shadow:inset 0 1px 2px rgba(20,24,17,.7)}html[data-theme="vapor"] .game-card:hover{transform:none}
  .shell{position:relative;padding-top:4rem}.theme-switcher{position:absolute;z-index:20;top:1rem;right:0}.theme-toggle{display:grid;width:2.75rem;height:2.75rem;place-items:center;padding:0;border:1px solid var(--border-strong);border-radius:var(--radius-control);background:var(--button);color:var(--button-text);box-shadow:0 2px 8px var(--shadow);cursor:pointer}.theme-toggle:hover,.theme-toggle[aria-expanded="true"]{border-color:var(--accent);background:var(--button-hover);color:var(--heading)}.theme-toggle svg{width:1.15rem;height:1.15rem}.theme-menu{position:absolute;right:0;top:calc(100% + .4rem);display:grid;width:9.5rem;padding:.3rem;border:1px solid var(--border-strong);border-radius:var(--radius-card);background:var(--panel);box-shadow:0 12px 30px var(--shadow)}.theme-menu[hidden]{display:none}.theme-option{display:flex;min-height:2.5rem;width:100%;align-items:center;gap:.55rem;padding:.45rem .6rem;border:0;border-radius:var(--radius-control);background:transparent;color:var(--text);font:inherit;font-size:.82rem;text-align:left;cursor:pointer}.theme-option:hover{background:var(--raised);color:var(--heading)}.theme-option[aria-pressed="true"]{color:var(--accent-text);font-weight:700}.theme-swatch{width:.75rem;height:.75rem;flex:none;border:1px solid var(--border-strong);border-radius:var(--radius-pill)}.theme-check{margin-left:auto;visibility:hidden}.theme-option[aria-pressed="true"] .theme-check{visibility:visible}html[data-theme="vapor"] .theme-toggle{border-color:#76866b #3f4738 #3f4738 #76866b;box-shadow:inset 0 1px 0 rgba(239,246,238,.1),0 1px 2px var(--shadow);text-shadow:0 1px rgba(20,24,17,.65)}html[data-theme="vapor"] .theme-toggle:active{border-color:#3f4738 #76866b #76866b #3f4738;box-shadow:inset 0 1px 2px rgba(20,24,17,.7)}@media(max-width:720px){.shell{padding-top:3.75rem}.theme-switcher{top:.5rem}}
  """

  @javascript """
  (()=>{const root=document.documentElement;const switcher=document.querySelector("[data-theme-switcher]");if(!switcher)return;const toggle=switcher.querySelector("[data-theme-toggle]");const menu=switcher.querySelector("[data-theme-menu]");const options=[...switcher.querySelectorAll("[data-theme-option]")];const option=theme=>options.find(item=>item.dataset.themeOption===theme);const updateLinks=theme=>{document.querySelectorAll('a[href]:not([target])').forEach(link=>{const href=link.getAttribute("href");if(!href||/^(?:[a-z][a-z0-9+.-]*:|#|\\/\\/)/i.test(href))return;const hashAt=href.indexOf("#");const hash=hashAt>=0?href.slice(hashAt):"";const pathAndQuery=hashAt>=0?href.slice(0,hashAt):href;const queryAt=pathAndQuery.indexOf("?");const path=queryAt>=0?pathAndQuery.slice(0,queryAt):pathAndQuery;const params=new URLSearchParams(queryAt>=0?pathAndQuery.slice(queryAt+1):"");params.set("theme",theme);link.setAttribute("href",`${path}?${params}${hash}`)})};const apply=(theme,persist=false)=>{const selected=option(theme);if(!selected)return;root.dataset.theme=theme;document.querySelector('meta[name="theme-color"]')?.setAttribute("content",selected.dataset.themeColor);options.forEach(item=>item.setAttribute("aria-pressed",(item===selected).toString()));updateLinks(theme);if(persist){try{localStorage.setItem("iri-static-theme",theme)}catch(_error){}try{const current=new URL(location.href);current.searchParams.set("theme",theme);history.replaceState(null,"",current)}catch(_error){}}};let stored=null;try{stored=localStorage.getItem("iri-static-theme")}catch(_error){}const requested=new URLSearchParams(location.search).get("theme");const initial=option(requested)?requested:option(stored)?stored:root.dataset.theme;apply(initial);const close=()=>{menu.hidden=true;toggle.setAttribute("aria-expanded","false")};toggle.addEventListener("click",()=>{const opening=menu.hidden;menu.hidden=!opening;toggle.setAttribute("aria-expanded",opening.toString());if(opening)(options.find(item=>item.getAttribute("aria-pressed")==="true")||options[0])?.focus()});options.forEach(item=>item.addEventListener("click",()=>{apply(item.dataset.themeOption,true);close();toggle.focus()}));document.addEventListener("click",event=>{if(!switcher.contains(event.target))close()});document.addEventListener("keydown",event=>{if(event.key==="Escape"&&!menu.hidden){close();toggle.focus()}})})();
  (()=>{const list=document.querySelector("[data-collection-list]");if(list){const items=[...list.querySelectorAll("[data-game-entry]")];const search=document.querySelector("[data-search]");const sort=document.querySelector("[data-sort]");const direction=document.querySelector("[data-direction]");let dir="asc";const value=(item,key)=>key==="title"?item.dataset.title:(Number(item.dataset[key])||0);const refresh=()=>{const query=(search?.value||"").trim().toLocaleLowerCase();items.forEach(item=>item.hidden=!item.dataset.search.includes(query));const key=sort?.value||"position";items.sort((a,b)=>{const left=value(a,key),right=value(b,key);const result=typeof left==="string"?left.localeCompare(right):left-right;return (dir==="asc"?result:-result)||(Number(a.dataset.position)-Number(b.dataset.position))});items.forEach(item=>list.append(item));if(direction){const asc=dir==="asc";direction.textContent=asc?"↑ Ascending":"↓ Descending";direction.setAttribute("aria-label",`Sort direction: ${asc?"ascending":"descending"}. Change to ${asc?"descending":"ascending"}`)}const summary=document.querySelector("[data-result-summary]");if(summary){const visible=items.filter(item=>!item.hidden).length;summary.textContent=query?`${visible} of ${items.length} ${items.length===1?"game":"games"} shown`:""}};search?.addEventListener("input",refresh);sort?.addEventListener("change",refresh);direction?.addEventListener("click",()=>{dir=dir==="asc"?"desc":"asc";refresh()});refresh()}document.querySelectorAll("[data-sensitive-trigger]").forEach(trigger=>{const image=trigger.querySelector("[data-sensitive]");if(!image)return;trigger.addEventListener("click",()=>{const revealed=image.classList.toggle("revealed");trigger.setAttribute("aria-pressed",revealed.toString());trigger.setAttribute("aria-label",revealed?"Hide sensitive image":"Reveal sensitive image")})})})();
  (()=>{const dialog=document.querySelector("[data-lightbox]");if(!dialog)return;const triggers=[...document.querySelectorAll("[data-lightbox-trigger]")];const image=dialog.querySelector("[data-lightbox-image]");const previous=dialog.querySelector("[data-lightbox-previous]");const next=dialog.querySelector("[data-lightbox-next]");const status=dialog.querySelector("[data-lightbox-status]");let index=0;const show=current=>{index=(current+triggers.length)%triggers.length;const trigger=triggers[index];image.src=trigger.dataset.lightboxSrc;image.alt=trigger.dataset.lightboxAlt||"Enlarged screenshot";previous.hidden=next.hidden=triggers.length<2;if(status)status.textContent=`${index+1} of ${triggers.length}: ${image.alt}`};const open=current=>{show(current);if(typeof dialog.showModal==="function")dialog.showModal();else dialog.setAttribute("open","")};triggers.forEach((trigger,current)=>trigger.addEventListener("click",event=>{const sensitive=trigger.querySelector("[data-sensitive]:not(.revealed)");if(sensitive){event.preventDefault();event.stopPropagation();sensitive.classList.add("revealed");trigger.setAttribute("aria-label",trigger.dataset.lightboxLabel||"Enlarge screenshot");return}open(current)},true));dialog.querySelector("[data-lightbox-close]").addEventListener("click",()=>dialog.close());previous.addEventListener("click",()=>show(index-1));next.addEventListener("click",()=>show(index+1));dialog.addEventListener("click",event=>{if(event.target===dialog)dialog.close()});document.addEventListener("keydown",event=>{if(!dialog.open)return;if(event.key==="ArrowLeft")show(index-1);if(event.key==="ArrowRight")show(index+1)})})();
  if("serviceWorker" in navigator&&/^https?:$/.test(location.protocol)){navigator.serviceWorker.register("./service-worker.js",{scope:"./",updateViaCache:"none"}).catch(()=>{})}
  """

  def build(export, theme \\ "dark")

  def build(%{collection: collection, owner_name: owner_name, entries: entries}, theme) do
    theme = normalize_theme(theme)
    directory = collection_directory(collection)
    {entries, cover_files} = attach_covers(entries)

    document_files =
      [{"#{directory}/index.html", index_html(collection, owner_name, entries, theme)}] ++
        Enum.map(entries, fn entry ->
          {"#{directory}/#{entry.page_name}", game_html(collection, owner_name, entry, theme)}
        end)

    shared_files = cover_files

    service_worker =
      {"#{directory}/service-worker.js",
       service_worker(directory, document_files ++ shared_files)}

    files =
      (document_files ++ shared_files ++ [service_worker])
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, contents} -> {String.to_charlist(name), contents} end)

    case :zip.create(~c"iri-collection.zip", files, [:memory]) do
      {:ok, {_filename, archive}} -> {:ok, archive}
      {:error, reason} -> {:error, reason}
    end
  end

  def collection_directory(collection) do
    case safe_segment(collection.name) do
      "" -> "collection-#{collection.id}"
      name -> name
    end
  end

  defp attach_covers(entries) do
    Enum.map_reduce(entries, [], fn entry, files ->
      page_name = "game-#{safe_game_segment(entry)}.html"

      case cached_cover(entry) do
        {:ok, path, contents} ->
          {Map.merge(entry, %{cover_path: "../#{path}", page_name: page_name}),
           [{path, contents} | files]}

        :none ->
          {Map.merge(entry, %{cover_path: nil, page_name: page_name}), files}
      end
    end)
  end

  defp cached_cover(%{media_mode: :hide}), do: :none

  defp cached_cover(entry) do
    cover =
      Enum.find(
        entry.game.media_assets,
        &(&1.kind == "cover" and &1.cache_status == "ready")
      )

    with %{id: id} <- cover,
         {:ok, asset, source_path} <- Media.get_cached_asset(id),
         {:ok, contents} <- File.read(source_path) do
      digest = safe_content_hash(asset.content_hash) || content_hash(contents)
      {:ok, "assets/covers/#{digest}#{image_extension(source_path)}", contents}
    else
      _missing -> :none
    end
  end

  defp index_html(collection, owner_name, entries, theme) do
    cards = Enum.map_join(entries, "\n", &index_card/1)

    page(
      collection.name,
      """
      <main class="shell">
        #{theme_control(theme)}
        <header class="topbar">
          <div><p class="eyebrow">IRI collection</p><h1 class="page-title">#{h(collection.name)}</h1><p class="muted">#{h(owner_name)} · #{length(entries)} #{plural(length(entries), "game", "games")}</p></div>
        </header>
        <section class="controls" aria-label="Collection controls">
          <input class="control" type="search" data-search placeholder="Search this collection…" aria-label="Search this collection">
          <select class="control" data-sort aria-label="Sort collection"><option value="position">Collection order</option><option value="title">Title</option><option value="year">Release year</option><option value="rating">#{h(owner_name)}'s rating</option><option value="playtime">Playtime</option><option value="igdb">IGDB rating</option></select>
          <button class="button" type="button" data-direction aria-label="Sort direction: ascending. Change to descending">↑ Ascending</button>
        </section>
        <p class="sr-only" role="status" data-result-summary></p>
        <section class="collection-grid" data-collection-list><h2 class="sr-only">Games</h2>#{if(cards == "", do: ~s(<p class="empty">This collection is empty.</p>), else: cards)}</section>
        <footer class="footer">Exported from Iri.</footer>
      </main>
      """,
      theme
    )
  end

  defp index_card(entry) do
    year = entry.release_year || 0
    rating = entry.personal_rating || 0
    igdb = entry.igdb_rating || 0
    search = String.downcase("#{entry.title} #{entry.comment || ""}")

    """
    <article class="game-card" data-game-entry data-position="#{entry.position}" data-title="#{ha(String.downcase(entry.title))}" data-year="#{year}" data-rating="#{rating}" data-playtime="#{entry.playtime_minutes}" data-igdb="#{igdb}" data-search="#{ha(search)}">
      <a class="cover" href="#{ha(page_href(entry))}" tabindex="-1" aria-hidden="true">#{cover_markup(entry, :decorative)}</a>
      <div class="card-body"><h2 class="game-title"><a href="#{ha(page_href(entry))}">#{h(entry.title)}</a></h2><div class="metadata">#{year_chip(entry.release_year)}#{rating_chip(entry.personal_rating)}#{playtime_chip(entry.playtime_minutes)}</div>#{comment_markup(entry.comment)}</div>
    </article>
    """
  end

  defp game_html(collection, owner_name, entry, theme) do
    game = entry.game
    screenshots = remote_media(game.media_assets, "screenshot", entry.media_mode)
    videos = remote_media(game.media_assets, "video", :allow)
    terms = TaxonomyTerm.deduplicate(game.terms)

    page(
      "#{entry.title} · #{collection.name}",
      """
      <main class="shell">
        #{theme_control(theme)}
        <header class="detail-header"><a class="back-link" href="./">← #{h(collection.name)}</a></header>
        <section class="hero"><div class="hero-cover">#{cover_markup(entry)}</div><div><p class="eyebrow">#{h(collection.name)}</p><h1 class="detail-title">#{h(entry.title)}</h1><div class="metadata">#{year_chip(entry.release_year)}#{igdb_chip(entry.igdb_rating)}#{rating_chip(entry.personal_rating, owner_name)}#{playtime_chip(entry.playtime_minutes)}#{store_links_inline(entry.store_links)}</div>#{sensitive_note(entry.media_mode)}#{comment_section(entry.comment)}#{summary_section(game.summary)}</div></section>
        #{companies_section(game.game_companies)}
        #{tags_section(terms)}
        #{screenshots_section(screenshots, entry)}
        #{trailers_section(videos)}
        <footer class="footer">Exported from Iri.</footer>
      </main>
      """,
      theme
    )
  end

  defp page(title, body, theme) do
    theme_properties = Map.fetch!(@themes, theme)

    """
    <!doctype html><html lang="en" data-theme="#{h(theme)}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><meta name="theme-color" content="#{h(theme_properties.color)}"><title>#{h(title)}</title><style>#{@stylesheet}#{@lightbox_stylesheet}#{@theme_stylesheets}#{@theme_overrides}</style></head><body>#{body}<script>#{@javascript}</script></body></html>
    """
  end

  defp normalize_theme(theme) when is_map_key(@themes, theme), do: theme
  defp normalize_theme(_theme), do: "dark"

  defp theme_control(selected_theme) do
    options =
      Enum.map_join(@theme_order, fn name ->
        theme = Map.fetch!(@themes, name)

        ~s(<button class="theme-option" type="button" data-theme-option="#{h(name)}" data-theme-color="#{h(theme.color)}" aria-pressed="#{name == selected_theme}"><span class="theme-swatch" style="background:#{h(theme.color)}" aria-hidden="true"></span><span>#{h(theme.label)}</span><span class="theme-check" aria-hidden="true">✓</span></button>)
      end)

    """
    <div class="theme-switcher" data-theme-switcher>
      <button class="theme-toggle" type="button" data-theme-toggle aria-label="Choose theme" title="Theme" aria-controls="theme-menu" aria-expanded="false">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3a9 9 0 1 0 0 18h1.5a1.5 1.5 0 0 0 0-3H12a1.5 1.5 0 0 1 0-3h3.5A5.5 5.5 0 0 0 21 9.5C21 5.9 17 3 12 3Z"/><path d="M7.5 10h.01M9.5 6.75h.01M14 6.5h.01M17 9h.01"/></svg>
      </button>
      <div class="theme-menu" id="theme-menu" data-theme-menu role="group" aria-label="Choose theme" hidden>#{options}</div>
    </div>
    """
  end

  defp cover_markup(entry, context \\ :standalone)

  defp cover_markup(%{media_mode: :hide}, _context),
    do:
      ~s(<span class="cover-placeholder" role="img" aria-label="Sensitive media hidden">×</span>)

  defp cover_markup(%{cover_path: nil, title: title}, _context),
    do:
      ~s(<span class="cover-placeholder" aria-hidden="true">#{h(String.first(title) || "?")}</span>)

  defp cover_markup(%{media_mode: :blur} = entry, :standalone) do
    """
    <button class="sensitive-reveal" type="button" data-sensitive-trigger aria-label="Reveal sensitive image" aria-pressed="false"><img src="#{ha(entry.cover_path)}" alt="#{ha(entry.title)} cover" class="sensitive" data-sensitive></button>
    """
  end

  defp cover_markup(entry, context) do
    ~s(<img src="#{ha(entry.cover_path)}" alt="#{ha(entry.title)} cover"#{sensitive_attributes(entry.media_mode == :blur, context)}>)
  end

  defp comment_markup(nil), do: ""
  defp comment_markup(comment), do: ~s(<p class="comment">#{h(comment)}</p>)

  defp comment_section(nil), do: ""

  defp comment_section(comment) do
    ~s(<section class="section"><h2>Collection comment</h2><p class="comment">#{h(comment)}</p></section>)
  end

  defp summary_section(nil), do: ""
  defp summary_section(""), do: ""

  defp summary_section(summary) do
    ~s(<section class="section"><h2>About</h2><p>#{h(summary)}</p></section>)
  end

  defp companies_section([]), do: ""

  defp companies_section(relations) do
    companies =
      relations
      |> Enum.sort_by(&{&1.role, &1.company.name})
      |> Enum.map_join("", fn relation ->
        ~s(<span class="chip">#{h(String.capitalize(relation.role))}: #{h(relation.company.name)}</span>)
      end)

    ~s(<section class="section"><h2>Companies</h2><div class="tag-list">#{companies}</div></section>)
  end

  defp tags_section([]), do: ""

  defp tags_section(terms) do
    tags =
      Enum.map_join(terms, "", fn term ->
        ~s(<span class="chip">#{h(term.name)}</span>)
      end)

    ~s(<section class="section"><h2>Tags</h2><div class="tag-list">#{tags}</div></section>)
  end

  defp screenshots_section([], _entry), do: ""

  defp screenshots_section(screenshots, entry) do
    images =
      Enum.map_join(screenshots, "", fn screenshot ->
        alt = "Screenshot from #{entry.title}"
        lightbox_label = "Enlarge #{alt}"

        button_label =
          if entry.media_mode == :blur,
            do: "Reveal #{alt}",
            else: lightbox_label

        ~s(<button class="screenshot" type="button" data-lightbox-trigger data-lightbox-src="#{ha(screenshot.remote_url)}" data-lightbox-alt="#{ha(alt)}" data-lightbox-label="#{ha(lightbox_label)}" aria-label="#{ha(button_label)}"><img src="#{ha(screenshot.remote_url)}" alt=""#{sensitive_attributes(entry.media_mode == :blur, :lightbox)}></button>)
      end)

    ~s(<section class="section"><h2>Screenshots</h2><div class="screenshots">#{images}</div>#{lightbox_markup()}</section>)
  end

  defp lightbox_markup do
    """
    <dialog class="lightbox" data-lightbox aria-label="Screenshot viewer"><div class="lightbox-frame"><button class="lightbox-control lightbox-close" type="button" data-lightbox-close aria-label="Close screenshot">×</button><button class="lightbox-control lightbox-previous" type="button" data-lightbox-previous aria-label="Previous screenshot">‹</button><img class="lightbox-image" data-lightbox-image alt=""><button class="lightbox-control lightbox-next" type="button" data-lightbox-next aria-label="Next screenshot">›</button><p class="sr-only" role="status" data-lightbox-status></p></div></dialog>
    """
  end

  defp trailers_section([]), do: ""

  defp trailers_section(videos) do
    links =
      videos
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {video, index} ->
        ~s(<a class="store-link" href="#{ha(video.remote_url)}" target="_blank" rel="noreferrer">Trailer #{index}</a>)
      end)

    ~s(<section class="section"><h2>Trailers</h2><div class="link-list">#{links}</div></section>)
  end

  defp store_links_inline([]), do: ""

  defp store_links_inline(links) do
    Enum.map_join(links, "", fn link ->
      ~s(<a class="chip store-chip" href="#{ha(link.url)}" target="_blank" rel="noreferrer">#{h(link.store)} <span aria-hidden="true">↗</span></a>)
    end)
  end

  defp remote_media(_assets, kind, :hide) when kind == "screenshot", do: []

  defp remote_media(assets, kind, _mode) do
    assets
    |> Enum.filter(&(&1.kind == kind and web_url?(&1.remote_url)))
    |> Enum.sort_by(&{&1.position, &1.id})
  end

  defp web_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _other ->
        false
    end
  end

  defp web_url?(_url), do: false

  defp year_chip(year) when is_integer(year), do: ~s(<span class="chip">#{year}</span>)
  defp year_chip(_year), do: ""

  defp igdb_chip(rating) when is_number(rating),
    do: ~s(<span class="chip">IGDB #{round(rating)}%</span>)

  defp igdb_chip(_rating), do: ""

  defp rating_chip(rating, owner_name \\ nil)

  defp rating_chip(rating, owner_name)
       when is_number(rating) and rating >= 1 and rating <= 5 do
    label = if owner_name, do: "#{owner_name}'s rating", else: "Rating"

    ~s(<span class="chip rating" title="#{ha(label)}"><span class="sr-only">#{h(label)}: </span>#{rating_face(rating)} #{format_personal_rating(rating)}/5</span>)
  end

  defp rating_chip(_rating, _owner_name), do: ""

  defp playtime_chip(minutes) when is_integer(minutes) and minutes > 0 do
    hours = (minutes / 60) |> Float.round(1)
    ~s(<span class="chip">#{hours}h played</span>)
  end

  defp playtime_chip(_minutes), do: ""

  defp rating_face(rating) do
    face = ceil(rating)

    mouth =
      case face do
        1 ->
          ~s(<path d="m6 6.8 2.5 1.3M14 6.8l-2.5 1.3M7.5 10h.01M12.5 10h.01M6 14c2-3 6-3 8 0"/> )

        2 ->
          ~s(<path d="M6 14c2-2 6-2 8 0M6 8h2M12 8h2"/> )

        3 ->
          ~s(<path d="M6 13h8M6 8h2M12 8h2"/> )

        4 ->
          ~s(<path d="M6 12c2 3 6 3 8 0M6 8h2M12 8h2"/> )

        5 ->
          ~s(<path d="M5 11c2 5 8 5 10 0M5.5 7.5l2 1 1-2M14.5 7.5l-2 1-1-2"/> )
      end

    svg =
      ~s(<svg class="rating-face" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="10" cy="10" r="8"/>#{mouth}</svg>)

    if rating == trunc(rating) do
      svg
    else
      ~s(<span class="rating-face-wrap"><span class="rating-face-base">#{svg}</span><span class="rating-face-half">#{svg}</span></span>)
    end
  end

  defp format_personal_rating(rating) when is_integer(rating), do: Integer.to_string(rating)

  defp format_personal_rating(rating) when is_float(rating) do
    if rating == trunc(rating),
      do: rating |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(rating, decimals: 1)
  end

  defp sensitive_note(:blur),
    do:
      ~s(<p class="sensitive-note">Sensitive media is blurred. Interact with the image to reveal it.</p>)

  defp sensitive_note(:hide), do: ~s(<p class="sensitive-note">Sensitive media is hidden.</p>)
  defp sensitive_note(_mode), do: ""

  defp sensitive_attributes(true, :lightbox), do: ~s( class="sensitive" data-sensitive)
  defp sensitive_attributes(true, :decorative), do: ~s( class="sensitive")
  defp sensitive_attributes(false, _context), do: ""

  defp safe_game_segment(entry) do
    base = safe_segment(entry.slug || entry.title)
    if base == "", do: Integer.to_string(entry.game_id), else: "#{base}-#{entry.game_id}"
  end

  defp safe_segment(value) do
    value
    |> Title.slug()
    |> String.replace(~r/[^a-z0-9-]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 120)
  end

  defp image_extension(path) do
    case path |> Path.extname() |> String.downcase() do
      extension when extension in [".jpg", ".jpeg", ".png", ".webp"] -> extension
      _extension -> ".jpg"
    end
  end

  defp service_worker(directory, files) do
    cache_fingerprint =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(fn {name, contents} -> "#{name}:#{content_hash(contents)}" end)
      |> content_hash()
      |> String.slice(0, 16)

    cache_name = "iri-static-#{directory}-#{cache_fingerprint}"
    cache_prefix = "iri-static-#{directory}-"

    precache_paths =
      files
      |> Enum.map(&precache_path(directory, elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()

    """
    const CACHE=#{Jason.encode!(cache_name)};
    const PREFIX=#{Jason.encode!(cache_prefix)};
    const PRECACHE=#{Jason.encode!(precache_paths)};
    self.addEventListener("install",event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(PRECACHE)).then(()=>self.skipWaiting()))});
    self.addEventListener("activate",event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith(PREFIX)&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()))});
    self.addEventListener("fetch",event=>{if(event.request.method!=="GET")return;const url=new URL(event.request.url);const local=url.origin===self.location.origin;const image=event.request.destination==="image";if(!local&&!image)return;event.respondWith(caches.match(event.request).then(async cached=>{if(cached)return cached;if(local&&event.request.mode==="navigate"&&!url.pathname.endsWith("/")&&!url.pathname.endsWith(".html")){const html=await caches.match(url.href+".html");if(html)return html}const response=await fetch(event.request);if(response.ok||response.type==="opaque"){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy))}return response}))});
    """
  end

  defp precache_path(directory, name) do
    case String.trim_leading(name, "#{directory}/") do
      ^name -> "../#{name}"
      relative -> relative
    end
  end

  defp safe_content_hash(hash) when is_binary(hash) do
    if String.match?(hash, ~r/\A[0-9a-f]{32,128}\z/i), do: String.downcase(hash)
  end

  defp safe_content_hash(_hash), do: nil

  defp content_hash(contents),
    do: Base.encode16(:crypto.hash(:sha256, contents), case: :lower)

  defp page_href(entry), do: String.trim_trailing(entry.page_name, ".html")

  defp h(nil), do: ""

  defp h(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp ha(value), do: h(value)
  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural
end
