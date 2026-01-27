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
      token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjIxNDgyMzMyODksIm5iZiI6MTc2OTU0MjA4OSwic3ViIjoiZnJlZCIsImh0dHBzOi8vand0LmF0dGljLnJzL3YxIjp7ImNhY2hlcyI6eyJmcmVkIjp7InIiOjEsInciOjEsImNjIjoxfX19fQ.WhR5ixdW0j-wV77Tl8VubJPEyEvgQ8nQWYbgJxI8pPiLJN6v4DVaqKPu15mcY0N0B0zKnq9-njG5EOn2Z2-4dMgfx9ttTA-lltxrvPf5nKR9zAXg6hgPYsnGQuRFBvAFzlfPCpcIU2rgEVzMajzjipQgfUnVPDuto9uPU1VG25fncVRYz5dUhOXTfvN_WWpzcgQ7HDHQufbui5IoG-nmFMFWcNkxTCw7XVNs1PYFpadMGn6zAeh9Hi6epYYllr1aTcmTCx6ut3-fbFdQaxGG_HsCyxFiIf9r6GNSQvZOeHbeLcE21RQ6qNrkKZuQiVoOAcQr7ngpQ2jjcWnajw_hCPi6rqByZxdZy8IAbPQ83nm9o5UlfKg99sr6YSV-6ZTBvsOm-ioUX9hSktWm3O7cdH74ygmbUC_QL-os6aYNhbyQjSEMgiOpS65VnFURG58gnnvVHncMvohyDKwZqcWVtiaQApNeL3_LEATtX_zdqlaWdCVXO3t3QlD0ebYVhb4rn2KEg0GOZHGpWPqJnszRSMwXgWM1fG37OF117Qz6O9280BoEMdjLvITr5Cq0kQqS0PzapLdI5maU6ZluyqvAvgqdHzwjey4hDDq3FjITA_JMUStRlH7sMwtaSGTiTTOHQPe7WT9PImqfm4G8Q3urOsHMBE_Au1dqnUz4Lq-yU4M"
    '';
  };
}
