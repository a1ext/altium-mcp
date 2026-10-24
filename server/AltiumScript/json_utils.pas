// Helper function to remove characters from a string
function RemoveChar(const S: String; C: Char): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> C then
      Result := Result + S[I];
end;

// JSON utility functions for Altium MCP Bridge

function TrimJSON(InputStr: String): String;
begin
  // Remove quotes and commas
  Result := InputStr;
  Result := RemoveChar(Result, '"');
  Result := RemoveChar(Result, ',');
  // Trim whitespace
  Result := Trim(Result);
end;

// Helper function to escape JSON strings
function JSONEscapeString(const S: String): String;
var
    i, Code : Integer;
    Clean   : Boolean;
    T       : String;
begin
    Result := StringReplace(S, '\', '\\', REPLACEALL);
    Result := StringReplace(Result, '"', '\"', REPLACEALL);
    Result := StringReplace(Result, #13#10, '\n', REPLACEALL);
    Result := StringReplace(Result, #10, '\n', REPLACEALL);
    Result := StringReplace(Result, #13, '\n', REPLACEALL);
    Result := StringReplace(Result, #9, '\t', REPLACEALL);

    // Any other control character (pad names may carry them) is invalid
    // inside a JSON string and makes the whole response unparseable
    Clean := True;
    for i := 1 to Length(Result) do
        if (Ord(Result[i]) < 32) then
            Clean := False;
    if Clean then Exit;
    T := '';
    for i := 1 to Length(Result) do
    begin
        Code := Ord(Result[i]);
        if (Code < 32) then
            T := T + '\u' + IntToHex(Code, 4)
        else
            T := T + Result[i];
    end;
    Result := T;
end;

// Function to create a JSON name-value pair
function JSONPairStr(const Name, Value: String; IsString: Boolean): String;
begin
    if IsString then
        Result := '"' + JSONEscapeString(Name) + '": "' + JSONEscapeString(Value) + '"'
    else
        Result := '"' + JSONEscapeString(Name) + '": ' + Value;
end;

// Function to build a JSON object from a list of pairs
function BuildJSONObject(Pairs: TStringList; IndentLevel: Integer = 0): String;
var
    i: Integer;
    Output: TStringList;
    Indent, ChildIndent: String;
begin
    // Create indent strings based on level
    Indent := StringOfChar(' ', IndentLevel * 2);
    ChildIndent := StringOfChar(' ', (IndentLevel + 1) * 2);
    
    Output := TStringList.Create;
    try
        Output.Add(Indent + '{');
        
        for i := 0 to Pairs.Count - 1 do
        begin
            if i < Pairs.Count - 1 then
                Output.Add(ChildIndent + Pairs[i] + ',')
            else
                Output.Add(ChildIndent + Pairs[i]);
        end;
        
        Output.Add(Indent + '}');
        
        Result := Output.Text;
    finally
        Output.Free;
    end;
end;

// Function to build a JSON array from a list of items
function BuildJSONArray(Items: TStringList; ArrayName: String = ''; IndentLevel: Integer = 0): String;
var
    i: Integer;
    Output: TStringList;
    Indent, ChildIndent: String;
begin
    // Create indent strings based on level
    Indent := StringOfChar(' ', IndentLevel * 2);
    ChildIndent := StringOfChar(' ', (IndentLevel + 1) * 2);
    
    Output := TStringList.Create;
    try
        if ArrayName <> '' then
            Output.Add(Indent + '"' + JSONEscapeString(ArrayName) + '": [')
        else
            Output.Add(Indent + '[');
        
        for i := 0 to Items.Count - 1 do
        begin
            if i < Items.Count - 1 then
                Output.Add(ChildIndent + Items[i] + ',')
            else
                Output.Add(ChildIndent + Items[i]);
        end;
        
        Output.Add(Indent + ']');
        
        Result := Output.Text;
    finally
        Output.Free;
    end;
end;

// Function to write JSON to a file and return as string
function WriteJSONToFile(JSON: TStringList; FileName: String = ''): String;
var
    TempFile: String;
    AutoName: Boolean;
begin
    // Use the provided .json filename; anything else is a folder (empty = the
    // shared exchange folder) that gets a temporary file, removed afterwards
    AutoName := Not(AnsiEndsStr('.json', LowerCase(FileName)));
    if AutoName then
    begin
        if FileName = '' then
            TempFile := 'C:\Users\Public\altium_mcp\'
        else
            TempFile := FileName;
        if Not(AnsiEndsStr('\', TempFile)) then
            TempFile := TempFile + '\';
        TempFile := TempFile + 'temp_json_output.json';
    end
    else
    begin
        TempFile := FileName;
    end;
    
    try
        // Save to file
        JSON.SaveToFile(TempFile);
        
        // Load back the complete JSON data
        JSON.Clear;
        JSON.LoadFromFile(TempFile);
        Result := JSON.Text;
        
        // Clean up temporary file if auto-generated
        if AutoName and FileExists(TempFile) then
            DeleteFile(TempFile);
    except
        Result := '{"error": "Failed to write JSON to file"}';
    end;
end;

// Locale-safe StrToFloat: normalizes '.' to the system decimal separator before parsing.
// Mirrors AddJSONNumber which does the reverse on output (fwolter PR #3).
function SafeStrToFloat(S: String): Double;
begin
    S := StringReplace(S, '.', DecimalSeparator, REPLACEALL);
    Result := StrToFloat(S);
end;

// Helper function to add a simple property to a JSON object
procedure AddJSONProperty(List: TStringList; Name: String; Value: String; IsString: Boolean = True);
begin
    List.Add(JSONPairStr(Name, Value, IsString));
end;

// Helper to add a numeric property
procedure AddJSONNumber(List: TStringList; Name: String; Value: Double);
begin
    List.Add(JSONPairStr(Name, StringReplace(FloatToStr(Value), ',', '.', REPLACEALL), False));
end;

// Helper to add an integer property
procedure AddJSONInteger(List: TStringList; Name: String; Value: Integer);
begin
    List.Add(JSONPairStr(Name, IntToStr(Value), False));
end;

// Helper to add a boolean property
procedure AddJSONBoolean(List: TStringList; Name: String; Value: Boolean);
begin
    if Value then
        List.Add(JSONPairStr(Name, 'true', False))
    else
        List.Add(JSONPairStr(Name, 'false', False));
end;

// Decode JSON string escapes: \\ \" \/ \n \r \t and \uXXXX
function JSONUnescape(S: String): String;
var
    i : Integer;
    C : String;
begin
    Result := '';
    i := 1;
    while (i <= Length(S)) do
    begin
        C := Copy(S, i, 1);
        if (C = '\') and (i < Length(S)) then
        begin
            i := i + 1;
            C := Copy(S, i, 1);
            if (C = 'n') then
                Result := Result + #10
            else if (C = 'r') then
                Result := Result + #13
            else if (C = 't') then
                Result := Result + #9
            else if (C = 'u') and (i + 4 <= Length(S)) then
            begin
                Result := Result + Chr(StrToInt('$' + Copy(S, i + 1, 4)));
                i := i + 4;
            end
            else
                Result := Result + C;
        end
        else
            Result := Result + C;
        i := i + 1;
    end;
end;

// The string value of a '"key": "value",' request line: the trailing comma
// and surrounding quotes removed and JSON escapes decoded. Unlike TrimJSON
// it keeps commas and quotes inside the value, so file paths arrive intact.
function JSONLineValue(Line: String): String;
var
    S : String;
begin
    S := Trim(Copy(Line, Pos(':', Line) + 1, Length(Line)));
    if (Copy(S, Length(S), 1) = ',') then
        S := Trim(Copy(S, 1, Length(S) - 1));
    if (Length(S) >= 2) and (Copy(S, 1, 1) = '"') and (Copy(S, Length(S), 1) = '"') then
        S := Copy(S, 2, Length(S) - 2);
    Result := JSONUnescape(S);
end;

// --- Request parameters --------------------------------------------------
// The server writes request.json with json.dump(indent=2): every top-level
// key starts its own line with exactly two spaces of indent, and every array
// element sits on its own line. Matching that exact prefix means a value
// that happens to look like a key ("x", "designators") is never mistaken
// for one.

// Index of the line holding top-level Key, -1 if the request has none
function ReqLine(RequestData: TStringList; Key: String): Integer;
var
    i      : Integer;
    Prefix : String;
begin
    Result := -1;
    Prefix := '  "' + Key + '":';
    for i := 0 to RequestData.Count - 1 do
        if (Copy(RequestData[i], 1, Length(Prefix)) = Prefix) then
        begin
            Result := i;
            Exit;
        end;
end;

// Decoded string value of a top-level key, Fallback when absent
function ReqString(RequestData: TStringList; Key: String; Fallback: String): String;
var
    i : Integer;
begin
    i := ReqLine(RequestData, Key);
    if (i < 0) then
        Result := Fallback
    else
        Result := JSONLineValue(RequestData[i]);
end;

// True when S is a plain JSON number. StrToFloat on anything else raises a
// conversion error that try/except does not catch in DelphiScript
function IsJSONNumber(S: String): Boolean;
var
    i : Integer;
    C : String;
begin
    Result := (S <> '');
    for i := 1 to Length(S) do
    begin
        C := Copy(S, i, 1);
        if (Pos(C, '0123456789.-+eE') = 0) then
            Result := False;
    end;
end;

function ReqFloat(RequestData: TStringList; Key: String; Fallback: Double): Double;
var
    S : String;
begin
    S := ReqString(RequestData, Key, '');
    if IsJSONNumber(S) then
        Result := SafeStrToFloat(S)
    else
        Result := Fallback;
end;

function ReqInt(RequestData: TStringList; Key: String; Fallback: Integer): Integer;
var
    S : String;
begin
    S := ReqString(RequestData, Key, '');
    if IsJSONNumber(S) then
        Result := Round(SafeStrToFloat(S))
    else
        Result := Fallback;
end;

function ReqBool(RequestData: TStringList; Key: String; Fallback: Boolean): Boolean;
var
    S : String;
begin
    S := LowerCase(ReqString(RequestData, Key, ''));
    if (S = 'true') then
        Result := True
    else if (S = 'false') then
        Result := False
    else
        Result := Fallback;
end;

// Elements of a top-level array of strings (or numbers), decoded, added to
// Items. Handles "key": [] on one line; an element may contain commas,
// brackets and escapes. Returns False when the key is absent.
function ReqArray(RequestData: TStringList; Key: String; Items: TStringList): Boolean;
var
    i : Integer;
    V : String;
begin
    i := ReqLine(RequestData, Key);
    Result := (i >= 0);
    if (i < 0) then Exit;
    if (Pos('[]', RequestData[i]) > 0) then Exit;
    i := i + 1;
    while (i < RequestData.Count) do
    begin
        V := Trim(RequestData[i]);
        if (V = ']') or (V = '],') then Exit;
        if (Copy(V, Length(V), 1) = ',') then
            V := Trim(Copy(V, 1, Length(V) - 1));
        if (Length(V) >= 2) and (Copy(V, 1, 1) = '"') and (Copy(V, Length(V), 1) = '"') then
            V := JSONUnescape(Copy(V, 2, Length(V) - 2));
        if (V <> '') then
            Items.Add(V);
        i := i + 1;
    end;
end;
