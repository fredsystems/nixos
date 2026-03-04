{
  pkgs,
  ...
}:
{
  home = {
    packages = with pkgs; [
      attic-client
    ];

    file.".config/attic/config.toml".text = ''
      default-server = "local"

      [servers.local]
      endpoint = "http://192.168.31.14:8080"
      token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIxNDgyNDY0MTcsIm5iZiI6MTc2OTU1NTIxNywic3ViIjoiZnJlZF9yb290IiwiaHR0cHM6Ly9qd3QuYXR0aWMucnMvdjEiOnsiY2FjaGVzIjp7IioiOnsiciI6MSwidyI6MSwiZCI6MSwiY2MiOjEsImNyIjoxLCJjcSI6MSwiY2QiOjF9fX19.GW_czSGrTAma8IiVoYUab9Cff8PCg4mbY0Y_v78JQwi13lM_2HUjbsF3hUvHLvVUj3yrXK68BTNp1c0vR0jXyDyfoyWszligOz275LDRdq9om09TbPvsaodZlxVtz5STQoAI40DzcjgBUB5JaiDiOKuKcYJSK2Yeql1PnOZZwUmlYx-3QNNSw9tFS9yw0rbJOW_XQ7bL-dq1LHwkuXk_rusxOTwaSO14IKANv4K2-slrlYYssTq9LVRlh8pO3EpYCPQzZXbIydc0RF7ZIiGWt_KthB-o9ytSl0nKOdLu3Zq2OYN3YW5dBBAvGj7yvWFMDVwREiIxz9CklqPmPJlXuEbV6UwUyrFyK8s-7pGdMNbvEwCAl3riV3GI3syH7tCP2KafyPTFObF29pFtBUvKDSC5bOBHmQ7LqY4q81hki4Q5a29rUsvb51JY4Sy6frhY1V_e3uQUhIHagMRSDR-PKuPdw1fOFC4LzHYCWC9mK87RyCFEIgIe_F--pOpDwLOb9gROnoi6AWm0gKop7Bn8J_3rOdCZHaWfkmtt57D7Tdv5DdO68u47shYKD3hIerxtbfAviZVBSOWtyylvc_jcLAOLWCPQyVADfwCHaJ-56s6PIiP3cjbg2waP_qBaBBc17EDx0t2yTU023LXmG13aPENBocJ78lAxqrf3wXdnSLo"
    '';
  };
}
