{$I Defines.inc}

unit ReviewThumbs;

{******************************************************************************}
{* Review - Media viewer plugin for FAR                                       *}
{* 2013, Max Rusov                                                            *}
{* License: WTFPL                                                             *}
{* Home: http://code.google.com/p/far-plugins/                                *}
{******************************************************************************}

{
ToDo:
  - Просмотр эскизов

  - Синхронизация с окном просмотора
  - Независимые режимы максимизации
  - Переход из окна просмтора в окно эскизов
  - Скроллер прокрутки

  - Оптимизация получения иконок (кэшировать расширения)

  - Выделение
    - Выделить все
    - Снятие выделения
    - Не выделять по "дребезгу" мыши?

  - Надписи:
    - Шрифт надписи
    - Вычисление высоты надписи
    - Свертка без пробелов
}

interface

  uses
    Windows,
    Commctrl,
    ShellAPI,
    MultiMon,
    Messages,
    MixTypes,
    MixUtils,
    MixFormat,
    MixStrings,
    MixClasses,
    MixWinUtils,
    MixWin,

    Far_API,
    FarCtrl,
    FarMenu,
    FarPlug,
    FarDlg,
    FarGrid,
    FarListDlg,
    FarColorDlg,
    FarConMan,

    PVAPI,
    GDIPAPI,
    GDIImageUtil,
    ReviewConst,
    ReviewDecoders,
    ReviewGDIPlus,
    ReviewClasses;


  const
    cThumbDeltaX  = 16;
    cThumbDeltaY  = 16;
    cTextHeight   = 32;

    cMinThumbSize = 16;
    cMaxThumbSize = 256;


  type
    TReviewThumb = class;
    TThumbsWindow = class;
    TThumbModalDlg = class;

    PSetThumbsRec = ^TSetThumbsRec;
    TSetThumbsRec = packed record
      Thumbs   :TObjList;
      Path     :TString;
      CurFile  :TString;
      WinMode  :Integer;
      WinRect  :TRect;
    end;

    
    TReviewThumb = class(TNamedObject)
    public
      constructor Create(const AName :TString; AFolder, ASelected :Boolean); overload;

    private
      FFolder   :Boolean;
      FSelected :Boolean;
      FIconIdx  :Integer;
    end;


    TThumbsWindow = class(TReviewWindow)
    public
      constructor Create; override;
      destructor Destroy; override;

    protected
      procedure PaintWindow(DC :HDC); override;
      function Idle :Boolean; override;

      procedure CMSetImage(var Mess :TMessage); message CM_SetImage;
      procedure CMMove(var Mess :TMessage); message CM_Move;
      procedure CMScale(var Mess :TMessage); message CM_Scale;
      procedure WMShowWindow(var Mess :TWMShowWindow); message WM_ShowWindow;
      procedure WMSetCursor(var Mess :TWMSetCursor); message WM_SetCursor;
      procedure WMLButtonDown(var Mess :TWMLButtonDown); message WM_LButtonDown;
      procedure WMLButtonDblClk(var Mess :TWMLButtonDblClk); message WM_LButtonDblClk;
      procedure WMMouseMove(var Mess :TWMMouseMove); message WM_MouseMove;
      procedure WMLButtonUp(var Mess :TWMLButtonUp); message WM_LButtonUp;
      procedure WMSize(var Mess :TWMSize); message WM_Size;

    private
      FThumbs     :TObjList;
      FPath       :TString;
      FThumbSize  :Integer;

      FWinSize    :TSize;
      FRowsCount  :Integer;
      FColsCount  :Integer;
      FColSplit   :Integer;
      FRowHeight  :Integer;
      FCurrent    :Integer;
      FDelta      :Integer;

      FDragged    :Boolean;

      FSysImages  :THandle;
      FImgSize    :TSize;
      FHandCursor :HCURSOR;

      FThumbThread :TThread;

      procedure FillStdIcons;
      procedure RecalcSizes;
      procedure SetSize(ASize :Integer);
      procedure ScrollTo(ADelta :Integer);
      procedure GoToItem(AIndex :Integer; AScroll, ASelect :Boolean);
      procedure SelectRange(AIdx, AIdx2 :Integer; AOn :Boolean);
      function GetItemRect(AIdx :Integer) :TRect;
      function CalcHotSpot(X, Y :Integer) :Integer;
      function Selected(AIdx :Integer) :Boolean;
    end;


    TThumbModalDlg = class(TModalStateDlg)
    public
      procedure UpdateTitle;

    protected
      procedure Prepare; override;
      procedure InitDialog; override;
      function KeyDown(AID :Integer; AKey :Integer) :Boolean; override;
      function MouseEvent(AID :Integer; const AMouse :TMouseEventRecord) :Boolean; override;
    end;


  function CollectThumb(const AFolder :TString) :TObjList;


  var ThumbsModalDlg :TThumbModalDlg;

  function ThumbModalState :Boolean;


{******************************************************************************}
{******************************} implementation {******************************}
{******************************************************************************}

  uses
    ReviewDlgDecoders,
    ReviewDlgGeneral,
    ReviewDlgSaveAs,
    ReviewDlgSlideShow,
    MixDebug;

  const
    cmMovePos    = 0;
    cmMoveSelect = 1;
    cmMoveScroll = 2;
    cmInvSelect  = 3;

 {-----------------------------------------------------------------------------}
 { TThumbsWindow                                                               }
 {-----------------------------------------------------------------------------}

  type
    TThumbThread = class(TThread)
    public
      constructor Create;
      destructor Destroy; override;

      procedure Execute; override;

(*    procedure AddTask(ATask :TTask);
      function CheckTask(ATask :TTask) :Boolean;
      procedure CancelTask(ATask :TTask);  *)

    private
      FEvent   :THandle;
      FTaskCS  :TRTLCriticalSection;
(*    FTask    :TTask; *)

      function DoTask :Boolean;
(*    procedure NextTask;
      procedure Render(ATask :TTask);  *)
    end;


  constructor TThumbThread.Create;
  begin
    inherited Create(False);
    FEvent := CreateEvent(nil, True, False, nil);
    InitializeCriticalSection(FTaskCS);
  end;


  destructor TThumbThread.Destroy; {override;}
  begin
    Terminate;
    SetEvent(FEvent);
    WaitFor;

(*  while FTask <> nil do
      NextTask;  *)
    CloseHandle(FEvent);
    DeleteCriticalSection(FTaskCS);
    inherited Destroy;
  end;


  procedure TThumbThread.Execute;
  var
    vRes :DWORD;
  begin
    while not Terminated do begin
      vRes := WaitForSingleObject(FEvent, 5000);
//    TraceF('WaitRes = %d', [integer(vRes)]);
      if Terminated then
        break;

      if vRes = WAIT_OBJECT_0 then begin
        ResetEvent(FEvent);
        while DoTask do;
      end;
    end;
  end;


  function TThumbThread.DoTask :Boolean;
  begin
    Result := False;
(*
    EnterCriticalSection(FTaskCS);
    try
      while (FTask <> nil) and (FTask.FState = tsCancelled) do
        NextTask;
      if FTask = nil then
        Exit;
      FTask.FState := tsProceed;
      if Assigned(FTask.FOnTask) then
        FTask.FOnTask(nil);
    finally
      LeaveCriticalSection(FTaskCS);
    end;

    Render(FTask);

    EnterCriticalSection(FTaskCS);
    try
      FTask.FState := tsReady;
      if Assigned(FTask.FOnTask) then
        FTask.FOnTask(nil);
      NextTask;
    finally
      LeaveCriticalSection(FTaskCS);
    end;

    Result := True;
*)
  end;


 {-----------------------------------------------------------------------------}
 { TThumbsWindow                                                               }
 {-----------------------------------------------------------------------------}

  constructor TThumbsWindow.Create; {override;}
  begin
    inherited Create;
    FThumbs := TObjList.Create;
    FThumbSize := optThumbSize;
    FHandCursor := LoadCursor(0, IDC_HAND);
    FThumbThread := TThumbThread.Create;
  end;


  destructor TThumbsWindow.Destroy; {override;}
  begin
    FreeObj(FThumbThread);
    FreeObj(FThumbs);
    inherited Destroy;
  end;


  procedure TThumbsWindow.WMShowWindow(var Mess :TWMShowWindow); {message WM_ShowWindow;}
  begin
    inherited;
    if Mess.Show then
      SetColor( FarAttrToCOLORREF(GetColorBG(optBkColor3)) );
  end;


  procedure TThumbsWindow.WMSize(var Mess :TWMSize); {message WM_Size;}
  begin
    inherited;
    RecalcSizes;
    ScrollTo(FDelta);
//  Invalidate;
  end;


  procedure TThumbsWindow.CMSetImage(var Mess :TMessage); {message CM_SetImage;}
  var
    vIndex :Integer;
  begin
    with PSetThumbsRec(Mess.LParam)^ do begin
      SetFullscreen( optFullscreen );

      FWinRect := WinRect;
      FWinBPP  := ScreenBitPerPixel;

      FLastArea := MACROAREA_SHELL;
      FNeedSync := False;

      FreeObj(FThumbs);
      FThumbs := Thumbs;
      FPath := Path;
      FCurrent := -1;
      FDelta := 0;

      FillStdIcons;
      RecalcSizes;
      if not IsWindowVisible(Handle) then
        ShowWindow
      else
      if FWinMode <> wmFullscreen then
        SetWindowBounds(CalcWinRect);

      if FThumbs.FindKey(Pointer(CurFile), 0, [], vIndex) then
        GoToItem(vIndex, True, False)
      else
        GoToItem(0, True, False);

      Invalidate;

//    FarAdvControl(ACTL_SYNCHRO, SyncCmdUpdateTitle);
    end;
  end;


  procedure TThumbsWindow.CMMove(var Mess :TMessage); {message CM_Move;}
  begin
    if (Mess.wParam = cmMovePos) or (Mess.wParam = cmMoveSelect) then
      GoToItem( Mess.LParam, True, Mess.wParam = cmMoveSelect)
    else
    if Mess.wParam = cmMoveScroll then
      ScrollTo( FDelta + Mess.LParam * FRowHeight )
    else
    if Mess.wParam = cmInvSelect then
      with TReviewThumb(FThumbs[Mess.LParam]) do
        SelectRange( Mess.LParam, Mess.LParam, not FSelected);
  end;


  procedure TThumbsWindow.CMScale(var Mess :TMessage); {message CM_Scale;}
  begin
    if Mess.wParam = 0 then
      SetSize( Mess.LParam )
    else
      SetSize( FThumbSize + Mess.LParam );
  end;


 {-----------------------------------------------------------------------------}

  procedure TThumbsWindow.WMSetCursor(var Mess :TWMSetCursor); {message WM_SetCursor;}
  var
    vIdx :Integer;
  begin
    inherited;
    with GetMousePos do
      vIdx := CalcHotSpot(X, Y);
    if vIdx <> -1 then
      SetCursor(FHandCursor);
  end;


  procedure TThumbsWindow.WMLButtonDown(var Mess :TWMLButtonDown); {message WM_LButtonDown;}
  var
    vIdx :Integer;
  begin
    SetCapture(Handle);
    with Mess.Pos do
      vIdx := CalcHotSpot(X, Y);
    if vIdx <> -1 then
      GoToItem(vIdx, False, GetKeyState(VK_Shift) < 0);
    FDragged := True;
    Mess.Result := 0;
  end;


  procedure TThumbsWindow.WMMouseMove(var Mess :TWMMouseMove); {message WM_MouseMove;}
  var
    vIdx :Integer;
  begin
    if FDragged then begin
      with Mess.Pos do
        vIdx := CalcHotSpot(X, Y);
      if vIdx <> -1 then
        GoToItem(vIdx, False, True);
    end;
    Mess.Result := 0;
  end;


  procedure TThumbsWindow.WMLButtonUp(var Mess :TWMLButtonUp); {message WM_LButtonUp;}
  begin
    if FDragged then begin
      ReleaseCapture;
      FDragged := False;
      GoToItem(FCurrent, True, False);
    end;
    Mess.Result := 0;
  end;



  procedure TThumbsWindow.WMLButtonDblClk(var Mess :TWMLButtonDblClk); {message WM_LButtonDblClk;}
  var
    vIdx :Integer;
  begin
    if GetKeyState(VK_Control) < 0 then begin
      if FWinMode <> wmQuickView then
        SetFullscreen( FWinMode = wmNormal )
    end else
    begin
      with Mess.Pos do
        vIdx := CalcHotSpot(X, Y);
      if vIdx <> -1 then
        with TReviewThumb(FThumbs[vIdx]) do
          if FFolder then begin
            if FPath <> '' then
              FarAdvControl(ACTL_SYNCHRO, TCmdObject.Create(CmdGoFolder, AddFileName(FPath, Name)) )
            else
              Beep;
          end else
            {};
    end;
    Mess.Result := 0;
  end;


 {-----------------------------------------------------------------------------}

  procedure TThumbsWindow.RecalcSizes;
  begin
    FWinSize := RectSize(ClientRect);

    if FThumbs.Count > 0 then begin
      FColsCount := IntMax(FWinSize.cx div (FThumbSize + cThumbDeltaX * 2), 1);
      FRowsCount := (FThumbs.Count + FColsCount - 1) div FColsCount;

      FColSplit := 0;
      if FColsCount > 1 then
        FColSplit := (FWinSize.cx - (FThumbSize + cThumbDeltaX * 2) * FColsCount) div (FColsCount - 1);

      FRowHeight := FThumbSize + cThumbDeltaY * 2 +
        cTextHeight; {!!! Вычистить высоту надписи... }
    end else
    begin
      FRowsCount := 0;
      FColsCount := 0;
      FColSplit  := 0;
      FRowHeight := 0;
      FDelta     := 0;
      FCurrent   := 0;
    end;
  end;


  procedure TThumbsWindow.SetSize(ASize :Integer);
  begin
    ASize := RangeLimit(ASize, cMinThumbSize, cMaxThumbSize);
    if ASize <> FThumbSize then begin
      FThumbSize := ASize;
      RecalcSizes;
      ScrollTo(FDelta);
      Invalidate;
    end;
  end;


  procedure TThumbsWindow.ScrollTo(ADelta :Integer);
  begin
    ADelta := RangeLimit(ADelta, 0, FRowsCount * FRowHeight - FWinSize.CY);
    if ADelta = FDelta then
      Exit;

    FDelta := ADelta;
    Invalidate; {!!! Прокручивать}
  end;


  function TThumbsWindow.Selected(AIdx :Integer) :Boolean;
  begin
    Result := TReviewThumb(FThumbs[AIdx]).FSelected;
  end;


  procedure TThumbsWindow.SelectRange(AIdx, AIdx2 :Integer; AOn :Boolean);
  var
    vCmd :TCmdObject;
  begin
    vCmd := TCmdObject.Create(IntIf(AOn, CmdSelect, CmdDeselect), '');
    try
      while True do begin
        with TReviewThumb(FThumbs[AIdx]) do begin
          if FSelected <> AOn then begin
            FSelected := AOn;
            Invalidate(GetItemRect(AIdx));
          end;
          vCmd.Add(Name);
        end;
        if AIdx = AIdx2 then
          break;
        if AIdx2 > AIdx then
          Inc(AIdx)
        else
          Dec(AIdx);
      end;
      if vCmd.Count > 0 then
        FarAdvControl(ACTL_SYNCHRO, vCmd);
    except
      vCmd.Destroy;
      raise;
    end;
  end;


  procedure TThumbsWindow.GoToItem(AIndex :Integer; AScroll, ASelect :Boolean);

    procedure MakeSelection(AOldPos, ANewPos :Integer);
    var
      vLock, vStart :Integer;
    begin
      if (ANewPos <> AOldPos) and Selected(AOldPos) then begin
        vLock := 0;
        if (AOldPos = FThumbs.Count - 1) or not Selected(AOldPos + 1) then
          vLock := 1
        else
        if (AOldPos = 0) or not Selected(AOldPos - 1) then
          vLock := -1;
        if vLock = 0 then
          vLock := -IntCompare(AOldPos, ANewPos);

        if vLock <> 0 then begin
          if vLock > 0 then begin
            vStart := AOldPos;
            while (vStart > 0) and Selected(vStart - 1) do
              Dec(vStart);
          end else
          begin
            vStart := AOldPos;
            while (vStart < FThumbs.Count - 1) and Selected(vStart + 1) do
              Inc(vStart);
          end;

          if ((AOldPos >= vStart) and (ANewPos < vStart)) or ((AOldPos <= vStart) and (ANewPos > vStart)) then begin
            if AOldPos <> vStart then
              SelectRange(vStart, AOldPos, False);
            SelectRange(vStart, ANewPos, True);
          end else
          begin
            if AOldPos >= vStart then begin
              if ANewPos > AOldPos then
                SelectRange(AOldPos + 1, ANewPos, True)
              else
                SelectRange(AOldPos, ANewPos + 1, False)
            end else
            begin
              if ANewPos < AOldPos then
                SelectRange(AOldPos - 1, ANewPos, True)
              else
                SelectRange(AOldPos, ANewPos - 1, False)
            end;
          end;
        end else
          {???};
      end else
        SelectRange(AOldPos, ANewPos, True);
    end;

  var
    vOldPos, vDelta :Integer;
  begin
    AIndex := RangeLimit(AIndex, 0, FThumbs.Count - 1);

    vOldPos := FCurrent;

    if AIndex <> FCurrent then begin
      Invalidate(GetItemRect(FCurrent));
      FCurrent := AIndex;
      Invalidate(GetItemRect(FCurrent));

      with TReviewThumb(FThumbs[FCurrent]) do
        FarAdvControl(ACTL_SYNCHRO, TCmdObject.Create(CmdSetFile, Name) );
    end;

    if ASelect then
      MakeSelection(vOldPos, FCurrent);

    if AScroll then begin
      vDelta := (FCurrent div FColsCount) * FRowHeight;
      if vDelta < FDelta then
        ScrollTo(vDelta)
      else
      if vDelta + FRowHeight > FDelta + FWinSize.CY then
        ScrollTo(vDelta + FRowHeight - FWinSize.CY);
    end;
  end;



  function TThumbsWindow.GetItemRect(AIdx :Integer) :TRect;
  var
    vCol, vRow :Integer;
  begin
    vRow := AIdx div FColsCount;
    vCol := AIdx mod FColsCount;
    Result := Bounds(
      vCol * (FThumbSize + cThumbDeltaX * 2 + FColSplit),
      (vRow * FRowHeight) - FDelta,
      FThumbSize + cThumbDeltaX * 2,
      FRowHeight
    );
  end;


  function TThumbsWindow.CalcHotSpot(X, Y :Integer) :Integer;
  var
    vRow, vCol, vIdx :Integer;
    vRect :TRect;
  begin
    Result := -1;

    vRow := (Y + FDelta) div FRowHeight;
    vCol := X div (FThumbSize + cThumbDeltaX * 2 + FColSplit);
    vIdx := (vRow * FColsCount) + vCol;

    if vIdx < FThumbs.Count then begin
      vRect := GetItemRect(vIdx);
      RectGrow(vRect, -cThumbDeltaX, -cThumbDeltaY);
      if RectContainsXY(vRect, X, Y) then
        Result := vIdx;
    end;
  end;


  procedure TThumbsWindow.PaintWindow(DC :HDC); {override;}

    procedure LocDrawTempText(const AStr :TString; {const} ARect :TRect);
    var
      vFont, vOldFont :HFont;
    begin
      vFont := GetStockObject(DEFAULT_GUI_FONT);
      vOldFont := SelectObject(DC, vFont);
      if vOldFont = 0 then
        Exit;
      try
//      SetBkMode(DC, OPAQUE);
//      SetBkColor(DC, FarAttrToCOLORREF(GetColorBG(optHintColor)));
        SetBkMode(DC, TRANSPARENT);

        SetTextColor(DC, FarAttrToCOLORREF(GetColorFG(optTextColor)));
        
//      TextOut(DC, X, Y, PTChar(AStr), Length(AStr));
        DrawText(DC, PTChar(AStr), Length(AStr), ARect, DT_CENTER or DT_TOP {or DT_NOCLIP} or DT_WORDBREAK {or DT_END_ELLIPSIS} or DT_END_ELLIPSIS);
      finally
        SelectObject(DC, vOldFont);
      end;
    end;


    procedure LocDrawImage(AItem :TReviewThumb; const ARect :TRect);
    begin
      GdiFillRect(DC, ARect, IntIf(AItem.FSelected, $0000FF, $FFFFFF));
//    LocDrawTempText(Int2Str(vItem.FIconIdx), vRect.Left, vRect.Top);

      if AItem.FIconIdx <> -1 then
        with RectCenter(ARect, FImgSize.CX, FImgSize.CY) do
          ImageList_Draw(FSysImages, AItem.FIconIdx, DC, Left, Top, 0);
    end;


    procedure PaintItem(AIndex :Integer; X, Y :Integer);
    var
      vItem :TReviewThumb;
      vRect :TRect;
    begin
      vItem := FThumbs[AIndex];
//    Trace('  Item %d, %s', [AIndex, ExtractFileName(vItem.Name)]);

      if AIndex = FCurrent then begin
        vRect := Bounds(X, Y, FThumbSize + cThumbDeltaX * 2, FThumbSize + cThumbDeltaY * 2 + cTextHeight);
        GdiFillRect(DC, vRect, $0000FF);
      end;

      vRect := Bounds(X + cThumbDeltaX, Y + cThumbDeltaY, FThumbSize, FThumbSize);
      LocDrawImage(vItem, vRect);

      vRect.Top := vRect.Bottom;
      vRect.Bottom := vRect.Top + cTextHeight;
//    GdiFillRect(DC, vRect, $FF0000);

      LocDrawTempText(ExtractFileName(vItem.Name), vRect);
    end;

  var
    {vClientRect,} vClipRect :TRect;
    vIdx, X, Y, vRow, vCol, vRow1, vRow2, vCol1, vCol2, vColWidth :Integer;
  begin
//  Trace('PaintWindow...');
//  vClientRect := ClientRect;
    try
      GetClipBox(DC, vClipRect);

      FillRect(DC, vClipRect, FBrush);

      vRow1 := (vClipRect.Top + FDelta) div FRowHeight;
      if vRow1 < FRowsCount then begin
        vRow2 := IntMin((vClipRect.Bottom + FDelta - 1) div FRowHeight + 1, FRowsCount);

        vColWidth := FThumbSize + cThumbDeltaX * 2 + FColSplit;

        vCol1 := vClipRect.Left div vColWidth;
        vCol2 := IntMin((vClipRect.Right - 1) div vColWidth + 1, FColsCount);

        Y := (vRow1 * FRowHeight) - FDelta;
        vIdx := vRow1 * FColsCount;
        for vRow := vRow1 to vRow2 - 1 do begin
          X := vCol1 * vColWidth;
          for vCol := vCol1 to vCol2 - 1 do begin
            if vIdx + vCol >= FThumbs.Count then
              Break;
            PaintItem(vIdx + vCol, X, Y);
            Inc(X, vColWidth);
          end;
          Inc(vIdx, FColsCount);
          Inc(Y, FRowHeight);
        end;
      end;

    except
      on E :Exception do begin
        FillRect(DC, vClipRect, FBrush);
//      DrawTempText(DC, E.Message);
      end;
    end;
  end;


  function TThumbsWindow.Idle :Boolean; {override;}
  begin
    Result := inherited Idle;

    if (FClipStart <> 0) and (TickCountDiff(GetTickCount, FClipStart) > 150) then begin
//    Trace('Clipped redraw...');
      FClipStart := 0;
//    FHiQual := not FDraftMode;
      RedrawWindow(Handle, nil, 0, RDW_INVALIDATE or RDW_ALLCHILDREN);
    end;
  end;


 {-----------------------------------------------------------------------------}


  procedure TThumbsWindow.FillStdIcons;
  var
    i, vFolder, vIdx :Integer;
    vFlags :UINT;
    vInfo :SHFILEINFO;
    vList :THandle;
    vItem :TReviewThumb;
  begin
   {$ifdef bDebug}
    TraceBeg('FillStdIcons');
   {$endif bDebug}

    vFolder := -1;
    for i := 0 to FThumbs.Count - 1 do begin
      vItem := FThumbs[i];
      if vItem.FFolder then
        vIdx := vFolder
      else
        vIdx := -1; {!!!Оптимизировать}
      if vIdx <> -1 then
        vItem.FIconIdx := vIdx
      else begin
        FillZero(vInfo, SizeOf(vInfo));
        vFlags := SHGFI_SYSICONINDEX {or SHGFI_SMALLICON} {or SHGFI_LARGEICON} {or SHGFI_SHELLICONSIZE}; 
        if not vItem.FFolder then
          vFlags := vFlags or SHGFI_USEFILEATTRIBUTES;
        vList := SHGetFileInfo( PTChar(vItem.Name), 0, vInfo, SizeOf(vInfo), vFlags );
        if vList <> 0 then begin
          if FSysImages = 0 then begin
            FSysImages := vList;
            ImageList_GetIconSize(FSysImages, FImgSize.CX, FImgSize.CY);
          end;
          vItem.FIconIdx := vInfo.iIcon;
          if vItem.FFolder then
            vFolder := vInfo.iIcon
          else
            {!!!}
        end;
      end;
    end;

   {$ifdef bDebug}
    TraceEnd('   Done');
   {$endif bDebug}
  end;


 {-----------------------------------------------------------------------------}
 { TReviewThumb                                                                }
 {-----------------------------------------------------------------------------}

  constructor TReviewThumb.Create(const AName :TString; AFolder, ASelected :Boolean);
  begin
    CreateName(AName);
    FFolder := AFolder;
    FSelected := ASelected;
    FIconIdx := -1;
  end;


 {-----------------------------------------------------------------------------}
 {                                                                             }
 {-----------------------------------------------------------------------------}

  function CollectThumb(const AFolder :TString) :TObjList;

    procedure FillFromPanel;
    var
      i :Integer;
      vInfo :TPanelInfo;
      vItem :PPluginPanelItem;
      vName :TString;
    begin
      if FarGetPanelInfo(PANEL_ACTIVE, vInfo) then begin
        if (vInfo.PanelType <> PTYPE_FILEPANEL) or (PFLAGS_REALNAMES and vInfo.Flags = 0) then
          Exit;
        for i := 0 to vInfo.ItemsNumber - 1 do begin
          vItem := FarPanelItem(PANEL_ACTIVE, FCTL_GETPANELITEM, i);
          if vItem <> nil then begin
            try
              vName := vItem.FileName;
              if vName = '..' then
                Continue;
              Result.Add( TReviewThumb.Create(
                vName,
                vItem.FileAttributes and faDirectory <> 0,
                PPIF_SELECTED and vItem.Flags <> 0) );
            finally
              MemFree(vItem);
            end;
          end;
        end;
      end;
    end;

    procedure FillFromFolder;
    begin
      Sorry;
    end;

  begin
    Result := TObjList.Create;
    try
      if AFolder = '' then
        FillFromPanel
      else
        FillFromFolder;
    except
      FreeObj(Result);
      raise;
    end;
  end;



 {-----------------------------------------------------------------------------}
 { Диалог модального состояния                                                 }
 {-----------------------------------------------------------------------------}

  procedure TThumbModalDlg.Prepare; {override;}
  var
    vTitle :TString;
  begin
    FHelpTopic := 'View'; //'Thumb';
    FGUID := cThumbDlgID;
    FFlags := FDLG_NODRAWSHADOW or FDLG_NODRAWPANEL;
    FWidth := 20;
    FHeight := 5;
    vTitle := Review.GetWindowTitle; {???}
    FDialog := CreateDialog(
      [ NewItemApi(DI_DoubleBox, 0,  0, FWidth, FHeight, 0, PTChar(vTitle)) ],
      @FItemCount
    );
  end;


  procedure TThumbModalDlg.InitDialog; {override;}
  begin
    ResizeDialog;
    UpdateTitle;
  end;


  procedure TThumbModalDlg.UpdateTitle;
  const
    vDelim = $2022;
  var
    vWin :TThumbsWindow;
    vStr :TString;
  begin
    vWin := Review.ThumbWindow as TThumbsWindow;
    vStr := vWin.FPath;
    vStr := vStr + ' ' + TChar(vDelim) + ' ' + Int2Str(vWin.FCurrent + 1) + ' / ' + Int2Str(vWin.FThumbs.Count);
    SetTitle(vStr);
  end;


  function TThumbModalDlg.KeyDown(AID :Integer; AKey :Integer) :Boolean; {override;}
  var
    vWin :TThumbsWindow;

    procedure LocGoto(AIdx :Integer);
    begin
      SendMessage(vWin.Handle, CM_Move, IntIf(AKey and Key_Shift <> 0, cmMoveSelect, cmMovePos), AIdx);
    end;

    procedure LocGotoPage(ADY :Integer);
    begin
      LocGoto(
        vWin.FCurrent + (vWin.FColsCount * (vWin.FWinSize.CY div vWin.FRowHeight)) * ADY);
    end;

    procedure LocMove(ADX, ADY :Integer);
    var
      vIdx :Integer;
    begin
      vIdx := vWin.FCurrent;
      vIdx := vIdx + ADX + ADY * vWin.FColsCount;
      LocGoto(vIdx);
    end;

    procedure LocSetScale(ADelta :Integer);
    begin
      SendMessage(vWin.Handle, CM_Scale, 1, ADelta);
    end;

  var
    vPath :TString;
  begin
    Result := True;

    vWin := Review.ThumbWindow as TThumbsWindow;

    if (AKey >= byte('A')) and (AKey <= byte('Z')) then
      AKey := AKey + 32;

    case AKey of
      KEY_F1 : begin
        Review.ThumbSyncDelayed(SyncCmdUpdateWin, 100);
        Result := inherited KeyDown(AID, AKey);
      end;

      KEY_F9 : begin
        Review.ThumbSyncDelayed(SyncCmdUpdateWin, 100);
        Review.PluginSetup;
      end;

      KEY_F10:
        Close;
      KEY_F4..KEY_F8,KEY_F11: begin
        FPostKey := AKey;
        Close;
      end;

      KEY_Enter:
//      Review.ThumbChangePath( AddFileName(vWin.FPath, TReviewThumb(vWin.FThumbs[vWin.FCurrent]).Name  ), '' );
        with TReviewThumb(vWin.FThumbs[vWin.FCurrent]) do
          if FFolder then
            Review.ThumbChangePath( AddFileName(vWin.FPath, Name), '' )
          else
            if Review.ShowImage( AddFileName(vWin.FPath, Name), 0) then
              ViewModalState(False, False);

      KEY_BS:
        begin
          vPath := ExtractFilePath(vWin.FPath);
          if not StrEqual(vPath, vWin.FPath) then
            Review.ThumbChangePath( vPath, ExtractFileName(vWin.FPath) )
          else
            Beep;
        end;

      { Смещение }
      Key_Left, Key_ShiftLeft, Key_NumPad4, Key_ShiftNumPad4:
        LocMove(-1,  0);
      Key_Right, Key_ShiftRight, Key_NumPad6, Key_ShiftNumPad6:
        LocMove(+1,  0);
      Key_Up, Key_ShiftUp, Key_NumPad8, Key_ShiftNumPad8:
        LocMove( 0, -1);
      Key_Down, Key_ShiftDown, Key_NumPad2, Key_ShiftNumPad2:
        LocMove( 0, +1);

      Key_Home, Key_ShiftHome, Key_NumPad7:
        LocGoto(0);
      Key_End, Key_ShiftEnd, Key_NumPad1:
        LocGoto(MaxInt);
      Key_PgDn, Key_ShiftPgDn, Key_NumPad3:
        LocGotoPage(+1);
      Key_PgUp, Key_ShiftPgUp, Key_NumPad9:
        LocGotoPage(-1);

      KEY_Ins:
        begin
          SendMessage(vWin.Handle, CM_Move, cmInvSelect, vWin.FCurrent);
          LocMove(+1,  0);
        end;
      KEY_Del:
        {};

      KEY_Add:
        LocSetScale( +1 );
      KEY_Subtract:
        LocSetScale( -1 );

      KEY_CtrlF, Byte('f') :
        Review.SetFullscreen(vWin.FWinMode = wmNormal);

      KEY_AltX : Sorry;

    else
      Result := inherited KeyDown(AID, AKey);
    end;
//  UpdateTitle;
  end;


  function TThumbModalDlg.MouseEvent(AID :Integer; const AMouse :TMouseEventRecord) :Boolean; {override;}
  var
    vWin :TThumbsWindow;
  begin
//  if AMouse.dwEventFlags and MOUSE_HWHEELED <> 0 then
//    {}
//  else
    if AMouse.dwEventFlags and MOUSE_WHEELED <> 0 then begin
      vWin := Review.ThumbWindow as TThumbsWindow;
      SendMessage(vWin.Handle, CM_Move, cmMoveScroll, IntIf(Smallint(LongRec(AMouse.dwButtonState).Hi) > 0, -1, 1) );
    end;
    Result := inherited MouseEvent(AID, AMouse);
  end;


  function ThumbModalState :Boolean;
  var
    vOldFullscrren :Boolean;
  begin
    Assert(ThumbsModalDlg = nil);
    ThumbsModalDlg := TThumbModalDlg.Create;
    try
      vOldFullscrren := optFullscreen;

      Result := ThumbsModalDlg.Run = -1;

      if vOldFullscrren <> optFullscreen then
        PluginConfig(True);

      if ThumbsModalDlg.FErrorStr <> '' then begin
        Review.CloseThumbWindow;
        ShowMessage(cPluginName, ThumbsModalDlg.FErrorStr, FMSG_WARNING or FMSG_MB_OK);
      end else
      begin
        Review.CloseThumbWindow;
        if ThumbsModalDlg.FPostKey <> 0 then
          FarPostMacro('Keys("' + FarKeyToName(ThumbsModalDlg.FPostKey) + '")');
      end;

    finally
      FreeObj(ThumbsModalDlg);
    end;
  end;


end.

